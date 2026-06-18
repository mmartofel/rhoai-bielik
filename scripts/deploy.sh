#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Główny skrypt deploymentu Bielik-11B-v2.3-Instruct na RHOAI 3.4
# Użycie: ./scripts/deploy.sh [--skip-prereqs] [--no-test]
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

for arg in "$@"; do
    case "${arg}" in
        --skip-prereqs) SKIP_PREREQS=true ;;
        --no-test)      NO_TEST=true ;;
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
echo -e "${BOLD}║    Deployment Bielik-11B-v2.3-Instruct na RHOAI 3.4         ║${NC}"
echo -e "${BOLD}║    Pipeline Parallelism (${PIPELINE_PARALLEL_SIZE}× NVIDIA T4) via Ray + llm-d  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# KROK 1: Weryfikacja wymagań wstępnych
# =============================================================================
log_step "Krok 1/6: Weryfikacja wymagań wstępnych"

if [ "${SKIP_PREREQS}" = true ]; then
    log_warn "Pomijam sprawdzenie prereqs (--skip-prereqs)"
else
    bash "${REPO_DIR}/manifests/00-prerequisites-check.sh" || \
        die "Sprawdzenie prereqs nieudane. Napraw błędy i uruchom ponownie."
fi

# =============================================================================
# KROK 2: Weryfikacja HF_TOKEN
# =============================================================================
log_step "Krok 2/6: Weryfikacja tokenu HuggingFace"

if [ -z "${HF_TOKEN:-}" ]; then
    log_warn "HF_TOKEN nie jest ustawiony w config/config.env"
    echo ""
    echo "Model Bielik-11B-v2.3-Instruct-GPTQ wymaga tokenu HuggingFace."
    echo "Utwórz konto na https://huggingface.co i pobierz token w Settings → Access Tokens."
    echo ""
    read -rsp "Podaj HF_TOKEN (input ukryty): " HF_TOKEN
    echo ""
    if [ -z "${HF_TOKEN}" ]; then
        die "HF_TOKEN jest wymagany do pobrania modelu z HuggingFace Hub"
    fi
    log_success "HF_TOKEN podany interaktywnie"
else
    log_success "HF_TOKEN jest ustawiony (długość: ${#HF_TOKEN} znaków)"
fi

export HF_TOKEN NAMESPACE

# =============================================================================
# KROK 3: Tworzenie namespace
# =============================================================================
log_step "Krok 3/7: Tworzenie namespace '${NAMESPACE}'"

oc apply -f "${REPO_DIR}/manifests/01-namespace.yaml"
log_success "Namespace '${NAMESPACE}' gotowy"

# =============================================================================
# KROK 4: Tworzenie Secret z tokenem HuggingFace
# =============================================================================
log_step "Krok 4/8: Tworzenie Secret 'hf-token' w namespace '${NAMESPACE}'"

# Secret musi istnieć PRZED ClusterStorageContainer (krok 5), bo CSC go referuje
if ! command -v envsubst &>/dev/null; then
    die "Narzędzie 'envsubst' nie jest dostępne. Zainstaluj 'gettext': brew install gettext (macOS) lub apt-get install gettext (Linux)"
fi

envsubst < "${REPO_DIR}/manifests/02-hf-secret.yaml.template" | oc apply -f -
log_success "Secret 'hf-token' zastosowany w namespace '${NAMESPACE}'"

# Krok 5 usunięty — ClusterStorageContainer nie jest używany przez llm-d controller.
# llm-d (llmisvc-controller-manager) generuje storage-initializer init container
# bezpośrednio (ignorując ClusterStorageContainer). HF_TOKEN jest wstrzykiwany
# do Deployment w kroku 7b, po tym jak llm-d stworzy Deployment z LLMInferenceService.

# =============================================================================
# KROK 6: AcceleratorProfile (GPU profile dla NVIDIA T4)
# =============================================================================
log_step "Krok 6/8: Tworzenie AcceleratorProfile 'nvidia-t4'"

if oc get crd acceleratorprofiles.dashboard.opendatahub.io &>/dev/null; then
    oc apply -f "${REPO_DIR}/manifests/05-accelerator-profile.yaml"
    log_success "AcceleratorProfile 'nvidia-t4' zastosowany w namespace redhat-ods-applications"
else
    log_warn "CRD AcceleratorProfile nie jest dostępny w tym klastrze — pomijam"
    log_warn "Pody będą używać nodeSelector + tolerations (GPU scheduling działa bez profilu)"
fi

# =============================================================================
# KROK 7: Deployment LLMInferenceService
# =============================================================================
log_step "Krok 7/8: Tworzenie LLMInferenceService 'bielik-11b-multinode'"

oc apply -f "${REPO_DIR}/manifests/03-llminferenceservice.yaml"
log_success "LLMInferenceService zaaplikowany"

echo ""
log_info "Parametry deploymentu:"
echo "  Model:                ${HF_MODEL_URI}"
echo "  Namespace:            ${NAMESPACE}"
echo "  Pipeline Parallel:    ${PIPELINE_PARALLEL_SIZE}× (stages Ray)"
echo "  Tensor Parallel:      ${TENSOR_PARALLEL_SIZE}× (GPU per nod)"
echo "  GPU per pod:          ${GPU_COUNT}× NVIDIA T4"
echo "  Max sequence length:  ${MAX_MODEL_LEN} tokenów"
echo "  GPU memory util:      ${GPU_MEMORY_UTILIZATION}"
echo ""

# =============================================================================
# KROK 7b: Wstrzyknięcie HF_TOKEN do storage-initializer init container
# =============================================================================
log_step "Krok 7b: Wstrzyknięcie HF_TOKEN do storage-initializer init container"

# llm-d controller tworzy Deployment bezpośrednio z własnym storage-initializer,
# ignorując ClusterStorageContainer. Musimy patchować Deployment PO jego stworzeniu.
# Patch przetrwa — llm-d reconciluje Deployment TYLKO przy zmianach w LLMInferenceService.
#
# Używamy strategic-merge patch zamiast json-patch:
# - json-patch /env/- wymaga że pole 'env' już istnieje → fragile
# - strategic-merge scala po kluczu 'name' kontenera → działa zawsze
log_info "Oczekiwanie na Deployment 'bielik-11b-multinode-kserve' z init container (max 90s)..."
WAIT_DEPLOY=0
while [ "${WAIT_DEPLOY}" -lt 90 ]; do
    # Poczekaj aż Deployment istnieje ORAZ storage-initializer jest już w spec
    INIT_CONTAINER=$(oc get deployment bielik-11b-multinode-kserve -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="storage-initializer")].name}' \
        2>/dev/null || echo "")
    if [ "${INIT_CONTAINER}" = "storage-initializer" ]; then
        break
    fi
    sleep 3
    WAIT_DEPLOY=$((WAIT_DEPLOY + 3))
done

if [ "${INIT_CONTAINER:-}" != "storage-initializer" ]; then
    log_warn "Deployment z storage-initializer nie pojawił się w 90s — pomijam inject HF_TOKEN"
    log_warn "Uruchom ręcznie: oc patch deployment bielik-11b-multinode-kserve -n ${NAMESPACE} --type=strategic-merge -p='{\"spec\":{\"template\":{\"spec\":{\"initContainers\":[{\"name\":\"storage-initializer\",\"env\":[{\"name\":\"HF_TOKEN\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"hf-token\",\"key\":\"token\"}}}]}]}}}}'"
else
    # Sprawdź czy HF_TOKEN już jest (idempotentność)
    EXISTING_HF=$(oc get deployment bielik-11b-multinode-kserve -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="storage-initializer")].env[?(@.name=="HF_TOKEN")].name}' \
        2>/dev/null || echo "")
    if [ "${EXISTING_HF}" = "HF_TOKEN" ]; then
        log_success "HF_TOKEN już jest w storage-initializer — pomijam patch"
    else
        # Strategic-merge scala init container po polu 'name' — dodaje env bez nadpisywania reszty
        oc patch deployment bielik-11b-multinode-kserve -n "${NAMESPACE}" \
            --type='strategic-merge' \
            -p='{"spec":{"template":{"spec":{"initContainers":[{"name":"storage-initializer","env":[{"name":"HF_TOKEN","valueFrom":{"secretKeyRef":{"name":"hf-token","key":"token"}}}]}]}}}}'
        log_success "HF_TOKEN wstrzyknięty do storage-initializer (strategic-merge po nazwie kontenera)"
        log_info "Deployment rollout — nowe pody pobiorą model z HF_TOKEN..."
    fi
fi

# =============================================================================
# KROK 8: Oczekiwanie na status READY
# =============================================================================
log_step "Krok 8/8: Oczekiwanie na READY (timeout: $((DEPLOY_TIMEOUT_SECONDS / 60)) minut)"

log_info "llm-d musi pobrać model (~7GB) i rozłożyć go na ${PIPELINE_PARALLEL_SIZE} nody..."
log_info "Polling co ${POLL_INTERVAL_SECONDS}s. Możesz śledzić postęp: ./scripts/status.sh"
echo ""

START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ "${ELAPSED}" -gt "${DEPLOY_TIMEOUT_SECONDS}" ]; then
        log_error "Timeout po $((DEPLOY_TIMEOUT_SECONDS / 60)) minutach"
        echo ""
        echo "Debugowanie:"
        echo "  oc get llminferenceservice -n ${NAMESPACE}"
        echo "  oc get pods -n ${NAMESPACE} -o wide"
        echo "  oc describe llminferenceservice bielik-11b-multinode -n ${NAMESPACE}"
        echo "  ./scripts/status.sh"
        exit 1
    fi

    # Sprawdź status LLMInferenceService
    READY_STATUS=$(oc get llminferenceservice bielik-11b-multinode \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || echo "Unknown")

    case "${READY_STATUS}" in
        "True")
            log_success "LLMInferenceService osiągnął status READY po ${ELAPSED}s"
            break
            ;;
        "False")
            REASON=$(oc get llminferenceservice bielik-11b-multinode \
                -n "${NAMESPACE}" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' \
                2>/dev/null || echo "")
            log_warn "[${ELAPSED}s] Status: NotReady — Powód: ${REASON:-oczekiwanie na zasoby}"
            ;;
        *)
            PODS_RUNNING=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
            log_info "[${ELAPSED}s] Status: ${READY_STATUS} — Pody Running: ${PODS_RUNNING}"
            ;;
    esac

    sleep "${POLL_INTERVAL_SECONDS}"
done

# --- Pobierz i wypisz URL endpointu ---
ENDPOINT_URL=$(oc get llminferenceservice bielik-11b-multinode \
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
    echo "Przykładowe użycie:"
    echo "  curl ${ENDPOINT_URL}/v1/models"
    echo "  curl ${ENDPOINT_URL}/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Cześć!\"}]}'"
else
    log_warn "URL endpointu niedostępny w statusie — sprawdź: oc get route -n ${NAMESPACE}"
fi
echo ""

# --- Opcjonalne uruchomienie testów ---
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
