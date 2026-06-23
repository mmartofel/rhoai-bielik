#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deployment Bielik-11B-v2.3-Instruct na RHOAI 3.4 — llm-d multi-node
#
# Przepływ:
#   1. Weryfikacja wymagań wstępnych
#   2. Weryfikacja tokenu HuggingFace
#   3. Namespace bielik-demo
#   4. MinIO (rhoai-model-registries) — jednorazowe uruchomienie
#   5. Secrety: huggingface-token + s3-data-connection
#   6. AcceleratorProfile (gpu-profile)
#   7. Job transferu modelu (HuggingFace → MinIO) — jednorazowe
#   8. LLMInferenceService — oczekiwanie na READY
#
# Użycie: ./scripts/deploy.sh [--skip-prereqs] [--no-test] [--skip-transfer]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/config/config.env"

# --- Kolory ANSI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Flagi ---
SKIP_PREREQS=false
NO_TEST=false
SKIP_TRANSFER=false

for arg in "$@"; do
    case "${arg}" in
        --skip-prereqs)  SKIP_PREREQS=true ;;
        --no-test)       NO_TEST=true ;;
        --skip-transfer) SKIP_TRANSFER=true ;;
    esac
done

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[BŁĄD]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

die() {
    log_error "$*"
    exit 1
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Deployment Bielik-11B-v2.3-Instruct na RHOAI 3.4          ║${NC}"
echo -e "${BOLD}║   Multi-node data parallelism (${PIPELINE_PARALLEL_SIZE}× T4) via llm-d        ║${NC}"
echo -e "${BOLD}║   Model storage: MinIO (cluster-local S3)                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# KROK 1: Weryfikacja wymagań wstępnych
# =============================================================================
log_step "Krok 1/8: Weryfikacja wymagań wstępnych"

if [ "${SKIP_PREREQS}" = true ]; then
    log_warn "Pomijam sprawdzenie prereqs (--skip-prereqs)"
else
    bash "${REPO_DIR}/manifests/00-prerequisites-check.sh" || \
        die "Sprawdzenie prereqs nieudane. Napraw błędy i uruchom ponownie."
fi

# =============================================================================
# KROK 2: Weryfikacja tokenu HuggingFace
# =============================================================================
log_step "Krok 2/8: Weryfikacja tokenu HuggingFace"

if [ "${SKIP_TRANSFER}" = true ]; then
    log_info "Pomijam transfer modelu (--skip-transfer) — token HF nie jest wymagany"
elif [ -z "${HF_TOKEN:-}" ]; then
    log_warn "HF_TOKEN nie jest ustawiony w config/config.env"
    echo ""
    read -rsp "Podaj HF_TOKEN (input ukryty): " HF_TOKEN
    echo ""
    if [ -z "${HF_TOKEN}" ]; then
        die "HF_TOKEN jest wymagany do pobrania modelu z HuggingFace Hub"
    fi
    log_success "HF_TOKEN podany interaktywnie"
else
    log_success "HF_TOKEN ustawiony (długość: ${#HF_TOKEN} znaków)"
fi

export HF_TOKEN NAMESPACE MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_ENDPOINT MINIO_BUCKET

# =============================================================================
# KROK 3: Namespace bielik-demo
# =============================================================================
log_step "Krok 3/8: Tworzenie namespace '${NAMESPACE}'"

NS_PHASE=$(oc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${NS_PHASE}" = "Terminating" ]; then
    log_warn "Namespace '${NAMESPACE}' jest w stanie Terminating — czekam na usunięcie (max 120s)..."
    WAIT_NS=0
    until [ "${WAIT_NS}" -ge 120 ] || ! oc get namespace "${NAMESPACE}" &>/dev/null; do
        WAIT_NS=$((WAIT_NS + 5))
        sleep 5
    done
    oc get namespace "${NAMESPACE}" &>/dev/null && \
        die "Namespace '${NAMESPACE}' nadal istnieje — sprawdź: oc get namespace ${NAMESPACE}"
    log_info "Namespace usunięty — tworzę od nowa"
fi

oc apply -f "${REPO_DIR}/manifests/01-namespace.yaml"
log_success "Namespace '${NAMESPACE}' gotowy"

# =============================================================================
# KROK 4: MinIO (rhoai-model-registries) — jednorazowe uruchomienie
# =============================================================================
log_step "Krok 4/8: MinIO w namespace '${MINIO_NAMESPACE}'"

oc apply -f "${REPO_DIR}/manifests/02-minio.yaml"

log_info "Oczekiwanie na gotowość MinIO (max 120s)..."
if ! oc rollout status deployment/minio -n "${MINIO_NAMESPACE}" --timeout=120s; then
    log_error "MinIO nie osiągnął gotowości w ciągu 120s"
    echo "  oc get pods -n ${MINIO_NAMESPACE}"
    echo "  oc logs deployment/minio -n ${MINIO_NAMESPACE}"
    die "Sprawdź logi MinIO powyżej"
fi
log_success "MinIO gotowy: ${MINIO_ENDPOINT}"

# Stwórz bucket przez jednorazowy Job (oc run --attach jest zawodny w trybie skryptowym)
log_info "Tworzenie bucketu '${MINIO_BUCKET}' (idempotentne)..."
oc delete job minio-bucket-init -n "${MINIO_NAMESPACE}" --ignore-not-found &>/dev/null

cat <<BUCKET_EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-bucket-init
  namespace: ${MINIO_NAMESPACE}
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: quay.io/minio/mc:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              mc alias set local http://minio:9000 minio minio123 &&
              mc mb -p local/${MINIO_BUCKET} &&
              echo "Bucket '${MINIO_BUCKET}' ready"
BUCKET_EOF

if oc wait --for=condition=complete job/minio-bucket-init \
    -n "${MINIO_NAMESPACE}" --timeout=90s 2>/dev/null; then
    log_success "Bucket '${MINIO_BUCKET}' gotowy"
else
    log_warn "Bucket init Job nie zakończył się w 90s"
    oc logs job/minio-bucket-init -n "${MINIO_NAMESPACE}" 2>/dev/null || true
    log_warn "Kontynuuję — bucket zostanie stworzony przez Job transferu"
fi
oc delete job minio-bucket-init -n "${MINIO_NAMESPACE}" --ignore-not-found &>/dev/null || true

# =============================================================================
# KROK 5: Secrety
# =============================================================================
log_step "Krok 5/8: Tworzenie secretów"

if ! command -v envsubst &>/dev/null; then
    die "'envsubst' niedostępne. Zainstaluj: brew install gettext (macOS) lub apt-get install gettext (Linux)"
fi

envsubst '${NAMESPACE} ${HF_TOKEN}' \
    < "${REPO_DIR}/manifests/03-hf-secret.yaml.template" | oc apply -f -
log_success "Secret 'huggingface-token' zastosowany"

envsubst '${NAMESPACE} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} ${MINIO_ENDPOINT} ${MINIO_BUCKET}' \
    < "${REPO_DIR}/manifests/04-s3-connection.yaml.template" | oc apply -f -
log_success "Secret 's3-data-connection' zastosowany"

envsubst '${NAMESPACE} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} ${MINIO_ENDPOINT}' \
    < "${REPO_DIR}/manifests/07-kserve-model-sa.yaml.template" | oc apply -f -
log_success "KServe SA 'bielik-model-sa' i secret 's3-creds-kserve' zastosowane"

# =============================================================================
# KROK 6: AcceleratorProfile (gpu-profile)
# =============================================================================
log_step "Krok 6/8: AcceleratorProfile"

oc apply -f "${REPO_DIR}/manifests/05-accelerator-profile.yaml" 2>/dev/null || \
    log_warn "AcceleratorProfile nie mógł być zastosowany (CRD może nie istnieć — kontynuuję)"
log_success "AcceleratorProfile zastosowany"

# =============================================================================
# KROK 7: Transfer modelu HuggingFace → MinIO (jednorazowy Job)
# =============================================================================
log_step "Krok 7/8: Transfer modelu do MinIO"

if [ "${SKIP_TRANSFER}" = true ]; then
    log_warn "Pomijam transfer modelu (--skip-transfer)"
else
    # Sprawdź czy model już istnieje w MinIO
    MODEL_EXISTS=false
    MINIO_POD=$(oc get pod -n "${MINIO_NAMESPACE}" -l app=minio \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "${MINIO_POD}" ]; then
        if oc exec "${MINIO_POD}" -n "${MINIO_NAMESPACE}" -- \
            ls "/data/${MINIO_BUCKET}/${MODEL_S3_PATH}/config.json" &>/dev/null 2>&1; then
            MODEL_EXISTS=true
        fi
    fi

    if [ "${MODEL_EXISTS}" = true ]; then
        log_success "Model już istnieje w MinIO (s3://${MINIO_BUCKET}/${MODEL_S3_PATH}/) — pomijam transfer"
    else
        log_info "Model nie znaleziony w MinIO — uruchamiam Job transferu..."
        log_warn "Pobieranie ~7 GB z HuggingFace — może potrwać do 60 minut"

        # Usuń poprzedni Job jeśli istnieje
        oc delete job bielik-model-transfer -n "${NAMESPACE}" --ignore-not-found &>/dev/null

        envsubst '${NAMESPACE}' \
            < "${REPO_DIR}/manifests/05-model-transfer-job.yaml.template" | oc apply -f -
        log_success "Job 'bielik-model-transfer' uruchomiony"

        log_info "Oczekiwanie na zakończenie transferu (timeout: $((TRANSFER_TIMEOUT_SECONDS / 60)) minut)..."
        log_info "Możesz śledzić postęp: oc logs -f job/bielik-model-transfer -n ${NAMESPACE}"
        echo ""

        if ! oc wait --for=condition=complete job/bielik-model-transfer \
            -n "${NAMESPACE}" \
            --timeout="${TRANSFER_TIMEOUT_SECONDS}s"; then
            log_error "Job transferu nie zakończył się w czasie lub zakończył błędem"
            echo "  Logi Joba:"
            oc logs job/bielik-model-transfer -n "${NAMESPACE}" --tail=50 || true
            echo ""
            echo "  Diagnoza:"
            echo "    oc describe job bielik-model-transfer -n ${NAMESPACE}"
            echo "    oc logs job/bielik-model-transfer -n ${NAMESPACE}"
            die "Transfer modelu nieudany. Sprawdź logi."
        fi

        log_success "Model przetransferowany do MinIO"
    fi
fi

# =============================================================================
# KROK 8: LLMInferenceService
# =============================================================================
log_step "Krok 8/9: Tworzenie LLMInferenceService 'bielik-11b'"

# The built-in data-parallel preset (v3-4-0-kserve-config-llm-worker-data-parallel)
# in redhat-ods-applications is used automatically by the llm-d operator when
# spec.parallelism.data is set — no custom config needed.
oc apply -f "${REPO_DIR}/manifests/06-llminferenceservice.yaml"
log_success "LLMInferenceService zaaplikowany"

echo ""
log_info "Konfiguracja deploymentu:"
echo "  Model:             s3://${MINIO_BUCKET}/${MODEL_S3_PATH}/"
echo "  Namespace:         ${NAMESPACE}"
echo "  Hardware profile:  gpu-profile (redhat-ods-applications)"
echo "  Pipeline Parallel: ${PIPELINE_PARALLEL_SIZE}× T4 (spec.worker → LeaderWorkerSet)"
echo "  Max seq length:    ${MAX_MODEL_LEN} tokenów"
echo "  GPU memory util:   ${GPU_MEMORY_UTILIZATION}"
echo ""

# =============================================================================
# Oczekiwanie na status READY
# =============================================================================
log_info "Oczekiwanie na READY (timeout: $((DEPLOY_TIMEOUT_SECONDS / 60)) minut)..."
log_info "Postęp: ./scripts/status.sh | oc get pods -n ${NAMESPACE} -w"
echo ""

START_TIME=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))

    if [ "${ELAPSED}" -gt "${DEPLOY_TIMEOUT_SECONDS}" ]; then
        log_error "Timeout po $((DEPLOY_TIMEOUT_SECONDS / 60)) minutach"
        echo "  oc get llminferenceservice -n ${NAMESPACE}"
        echo "  oc get pods -n ${NAMESPACE} -o wide"
        echo "  oc describe llminferenceservice bielik-11b -n ${NAMESPACE}"
        exit 1
    fi

    READY_STATUS=$(oc get llminferenceservice bielik-11b \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || echo "Unknown")

    case "${READY_STATUS}" in
        "True")
            log_success "LLMInferenceService osiągnął status READY po ${ELAPSED}s"
            break
            ;;
        "False")
            REASON=$(oc get llminferenceservice bielik-11b \
                -n "${NAMESPACE}" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' \
                2>/dev/null || echo "")
            log_warn "[${ELAPSED}s] NotReady — Powód: ${REASON:-oczekiwanie na zasoby}"
            ;;
        *)
            PODS_RUNNING=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
                grep -c "Running" || echo "0")
            log_info "[${ELAPSED}s] Status: ${READY_STATUS} — Pody Running: ${PODS_RUNNING}/${PIPELINE_PARALLEL_SIZE}"
            ;;
    esac

    sleep "${POLL_INTERVAL_SECONDS}"
done

# =============================================================================
# KROK 9: Playground (llama-stack)
# =============================================================================
log_step "Krok 9/9: Wdrożenie Playground (LlamaStackDistribution)"

oc apply -f "${REPO_DIR}/manifests/09-playground.yaml"
log_success "Playground 'lsd-genai-playground' zaaplikowany"
log_info "Playground dostępny w RHOAI: Gen AI studio → Playground"

ENDPOINT_URL=$(oc get llminferenceservice bielik-11b \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.url}' 2>/dev/null || echo "")

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ✅ DEPLOYMENT ZAKOŃCZONY SUKCESEM                          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
if [ -n "${ENDPOINT_URL}" ]; then
    echo -e "${GREEN}Endpoint URL:${NC} ${ENDPOINT_URL}"
    echo ""
    echo "  curl -k ${ENDPOINT_URL}/v1/models"
    echo "  curl -k ${ENDPOINT_URL}/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Cześć!\"}]}'"
else
    log_warn "URL endpointu niedostępny — sprawdź: oc get llminferenceservice -n ${NAMESPACE}"
fi
echo ""

if [ "${NO_TEST}" = false ]; then
    read -rp "Czy uruchomić testy inference? [T/n]: " RUN_TESTS
    case "${RUN_TESTS:-T}" in
        [Tt]* | "")
            bash "${REPO_DIR}/manifests/04-test-inference.sh"
            ;;
        *)
            log_info "Pominięto testy. Uruchom ręcznie: ./manifests/04-test-inference.sh"
            ;;
    esac
fi
