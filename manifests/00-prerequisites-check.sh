#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Skrypt weryfikacji wymagań wstępnych dla deploymentu Bielik-11B na RHOAI 3.4
# Uruchom przed deploy.sh lub jako standalone: ./manifests/00-prerequisites-check.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/config.env"

# --- Kolory ANSI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Licznik błędów ---
ERRORS=0

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✅ OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[⚠️  WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[❌ FAIL]${NC} $*"; ERRORS=$((ERRORS + 1)); }

check() {
    # Pomocnik: sprawdza warunek i wypisuje wynik
    # Użycie: check "opis" "komenda"
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        log_success "$desc"
        return 0
    else
        log_error "$desc"
        return 1
    fi
}

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Weryfikacja wymagań: Bielik-11B na RHOAI 3.4 (multi-node)  ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- 1. Dostępność oc CLI ---
log_info "Sprawdzanie oc CLI..."
if ! command -v oc &>/dev/null; then
    log_error "Narzędzie 'oc' nie jest dostępne w PATH"
    echo "  → Zainstaluj OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
    ERRORS=$((ERRORS + 1))
else
    log_success "'oc' CLI dostępne: $(oc version --client --short 2>/dev/null || oc version --client 2>/dev/null | head -1)"
fi

# --- 2. Zalogowanie do klastra ---
log_info "Sprawdzanie logowania do klastra..."
if ! oc whoami &>/dev/null; then
    log_error "Nie jesteś zalogowany do klastra OpenShift"
    echo "  → Uruchom: oc login <cluster-url>"
    ERRORS=$((ERRORS + 1))
else
    CURRENT_USER=$(oc whoami)
    CURRENT_SERVER=$(oc whoami --show-server 2>/dev/null || echo "nieznany")
    log_success "Zalogowany jako: ${CURRENT_USER} @ ${CURRENT_SERVER}"
fi

# Dalsze sprawdzenia wymagają połączenia z klastrem — przerwij jeśli brak
if [ "${ERRORS}" -gt 0 ]; then
    echo ""
    log_error "Krytyczne błędy przed połączeniem z klastrem. Napraw je i uruchom ponownie."
    exit 1
fi

# --- 3. Sprawdzenie RHOAI — DataScienceCluster ---
log_info "Sprawdzanie instalacji RHOAI (DataScienceCluster)..."
if ! oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null; then
    log_error "CRD DataScienceCluster nie istnieje — RHOAI może nie być zainstalowane"
else
    DSC_COUNT=$(oc get datasciencecluster --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${DSC_COUNT}" -eq 0 ]; then
        log_error "Nie znaleziono żadnego DataScienceCluster"
    else
        DSC_NAME=$(oc get datasciencecluster --all-namespaces --no-headers 2>/dev/null | awk '{print $2}' | head -1)
        DSC_NS=$(oc get datasciencecluster --all-namespaces --no-headers 2>/dev/null | awk '{print $1}' | head -1)

        # Sprawdź wersję RHOAI przez CSV lub annotations
        RHOAI_VERSION=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep -i "rhods\|rhoai\|opendatahub" | awk '{print $7}' | head -1 || echo "nieznana")
        log_success "DataScienceCluster '${DSC_NAME}' (ns: ${DSC_NS}) znaleziony, wersja RHOAI: ${RHOAI_VERSION}"
    fi
fi

# --- 4. Sprawdzenie czy llm-d jest włączony w DataScienceCluster ---
log_info "Sprawdzanie komponentu llm-d w DataScienceCluster..."
if oc get datasciencecluster --all-namespaces -o json 2>/dev/null | \
   python3 -c "
import json,sys
data=json.load(sys.stdin)
items=data.get('items',[])
for item in items:
    spec=item.get('spec',{}).get('components',{})
    llmd=spec.get('llmd',{}) or spec.get('kserve',{})
    management=llmd.get('managementState','')
    if management.lower()=='managed':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    log_success "Komponent llm-d jest włączony (managementState: Managed)"
else
    # Alternatywna metoda — sprawdź przez grep w JSON
    DSC_JSON=$(oc get datasciencecluster --all-namespaces -o json 2>/dev/null)
    if echo "${DSC_JSON}" | grep -qi '"llmd"'; then
        log_warn "Komponent llmd znaleziony w DataScienceCluster — zweryfikuj ręcznie status (managementState)"
        echo "  → Sprawdź: oc get datasciencecluster -o yaml | grep -A3 llmd"
    else
        log_error "Komponent llm-d nie jest widoczny w DataScienceCluster"
        echo "  → Sprawdź: oc edit datasciencecluster default i dodaj komponent llmd z managementState: Managed"
    fi
fi

# --- 5. Sprawdzenie CRD LLMInferenceService ---
log_info "Sprawdzanie CRD LLMInferenceService..."
if oc get crd llminferenceservices.serving.kserve.io &>/dev/null; then
    log_success "CRD llminferenceservices.serving.kserve.io istnieje"
else
    log_error "CRD llminferenceservices.serving.kserve.io nie istnieje"
    echo "  → llm-d operator musi być zainstalowany i w pełni uruchomiony"
    echo "  → Sprawdź: oc get csv -A | grep -i llmd"
fi

# --- 6. Nody GPU z labelem nvidia.com/gpu.present=true ---
log_info "Sprawdzanie nodów GPU (nvidia.com/gpu.present=true)..."
GPU_NODES=$(oc get nodes -l 'nvidia.com/gpu.present=true' --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${GPU_NODES}" -eq 0 ]; then
    log_error "Brak nodów z labelem nvidia.com/gpu.present=true"
    echo "  → Sprawdź: oc get nodes --show-labels | grep nvidia"
    echo "  → Sprawdź czy NFD i GPU Operator są zainstalowane i działają"
elif [ "${GPU_NODES}" -lt "${PIPELINE_PARALLEL_SIZE}" ]; then
    log_error "Zbyt mało nodów GPU: znaleziono ${GPU_NODES}, wymagane ${PIPELINE_PARALLEL_SIZE} (PIPELINE_PARALLEL_SIZE)"
    echo "  → Dodaj więcej nodów g4dn.2xlarge lub zmniejsz PIPELINE_PARALLEL_SIZE w config/config.env"
else
    log_success "Znaleziono ${GPU_NODES} nodów GPU (wymagane min: ${PIPELINE_PARALLEL_SIZE})"
    oc get nodes -l 'nvidia.com/gpu.present=true' --no-headers 2>/dev/null | \
        awk '{printf "    → Node: %-50s Status: %s\n", $1, $2}'
fi

# --- 7. GPU Operator ---
log_info "Sprawdzanie GPU Operator (nvidia-gpu-operator)..."
GPU_OP_NS="nvidia-gpu-operator"
if ! oc get namespace "${GPU_OP_NS}" &>/dev/null; then
    # Próbuj alternatywne nazwy namespace
    GPU_OP_NS=$(oc get namespace --no-headers 2>/dev/null | awk '{print $1}' | grep -i "gpu\|nvidia" | head -1 || echo "")
    if [ -z "${GPU_OP_NS}" ]; then
        log_warn "Namespace GPU Operator nie znaleziony (szukano: nvidia-gpu-operator)"
        echo "  → Sprawdź: oc get namespaces | grep -i gpu"
    fi
fi

if [ -n "${GPU_OP_NS}" ]; then
    RUNNING_PODS=$(oc get pods -n "${GPU_OP_NS}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    TOTAL_PODS=$(oc get pods -n "${GPU_OP_NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${RUNNING_PODS}" -gt 0 ]; then
        log_success "GPU Operator (ns: ${GPU_OP_NS}): ${RUNNING_PODS}/${TOTAL_PODS} podów w stanie Running"
    else
        log_error "GPU Operator (ns: ${GPU_OP_NS}): brak podów w stanie Running"
        echo "  → Sprawdź: oc get pods -n ${GPU_OP_NS}"
    fi
fi

# --- 8. AcceleratorProfile CRD i profil nvidia-t4 ---
log_info "Sprawdzanie AcceleratorProfile (GPU profile)..."
if ! oc get crd acceleratorprofiles.dashboard.opendatahub.io &>/dev/null; then
    log_warn "CRD AcceleratorProfile nie istnieje — profil GPU nie będzie zarejestrowany w Dashboard"
    echo "  → deploy.sh zastosuje AcceleratorProfile po zainstalowaniu RHOAI Dashboard"
else
    PROFILE_EXISTS=$(oc get acceleratorprofile nvidia-t4 -n redhat-ods-applications &>/dev/null && echo "yes" || echo "no")
    if [ "${PROFILE_EXISTS}" = "yes" ]; then
        log_success "AcceleratorProfile 'nvidia-t4' już istnieje w redhat-ods-applications"
    else
        log_warn "AcceleratorProfile 'nvidia-t4' nie istnieje — zostanie stworzony przez deploy.sh (krok 4)"
    fi
fi

# --- 9. Node Feature Discovery ---
log_info "Sprawdzanie Node Feature Discovery (NFD)..."
NFD_NS=$(oc get namespace --no-headers 2>/dev/null | awk '{print $1}' | grep -i "nfd\|node-feature" | head -1 || echo "")
if [ -z "${NFD_NS}" ]; then
    log_warn "NFD namespace nie znaleziony — sprawdź ręcznie: oc get pods -A | grep -i nfd"
else
    NFD_PODS=$(oc get pods -n "${NFD_NS}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    log_success "NFD (ns: ${NFD_NS}): ${NFD_PODS} podów Running"
fi

# --- Podsumowanie ---
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
if [ "${ERRORS}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ✅ Wszystkie wymagania spełnione. Możesz uruchomić deploy.sh  ${NC}"
else
    echo -e "${RED}${BOLD}  ❌ Znaleziono ${ERRORS} błąd(ów). Napraw je przed deploymentem.   ${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

[ "${ERRORS}" -eq 0 ] || exit 1
