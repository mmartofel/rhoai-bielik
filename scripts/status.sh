#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Skrypt sprawdzania statusu deploymentu Bielik-11B na RHOAI 3.4
# Użycie: ./scripts/status.sh [--watch]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/config/config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[BŁĄD]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

WATCH_MODE=false
[ "${1:-}" = "--watch" ] && WATCH_MODE=true

print_status() {

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Status deploymentu Bielik-11B — $(date '+%Y-%m-%d %H:%M:%S')     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

# =============================================================================
# Status LLMInferenceService
# =============================================================================
log_section "LLMInferenceService"

if ! oc get llminferenceservice bielik-11b -n "${NAMESPACE}" &>/dev/null; then
    log_error "LLMInferenceService 'bielik-11b' nie istnieje w namespace '${NAMESPACE}'"
    echo "  → Uruchom deployment: ./scripts/deploy.sh"
    return 1
fi

oc get llminferenceservice bielik-11b -n "${NAMESPACE}" \
    -o custom-columns=\
'NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,URL:.status.url' \
    2>/dev/null || oc get llminferenceservice bielik-11b -n "${NAMESPACE}"

# Szczegóły warunków
echo ""
log_info "Warunki statusu:"
oc get llminferenceservice bielik-11b -n "${NAMESPACE}" \
    -o jsonpath='{range .status.conditions[*]}  {.type}: {.status} ({.reason}) — {.message}{"\n"}{end}' \
    2>/dev/null || true

# =============================================================================
# Status podów + rozmieszczenie na nodach
# =============================================================================
log_section "Pody w namespace '${NAMESPACE}'"

oc get pods -n "${NAMESPACE}" -o wide --no-headers 2>/dev/null | \
    awk 'BEGIN{printf "%-45s %-12s %-8s %-50s\n","POD","STATUS","READY","NODE"}
         {printf "%-45s %-12s %-8s %-50s\n",$1,$4,$2,$7}'

# Walidacja multi-node: sprawdź czy pody są na różnych nodach
echo ""
log_info "Walidacja rozmieszczenia multi-node:"

NODES_LIST=$(oc get pods -n "${NAMESPACE}" -o wide --no-headers 2>/dev/null | \
    grep -v "Completed\|Evicted" | awk '{print $7}' | sort)
UNIQUE_NODES=$(echo "${NODES_LIST}" | sort -u | wc -l | tr -d ' ')
TOTAL_PODS=$(echo "${NODES_LIST}" | wc -l | tr -d ' ')

if [ "${TOTAL_PODS}" -eq 0 ]; then
    log_warn "Brak podów — deployment może być w toku"
elif [ "${UNIQUE_NODES}" -eq "${TOTAL_PODS}" ] && [ "${TOTAL_PODS}" -ge "${PIPELINE_PARALLEL_SIZE}" ]; then
    log_success "Multi-node OK: ${TOTAL_PODS} podów na ${UNIQUE_NODES} różnych nodach (wymagane: ${PIPELINE_PARALLEL_SIZE})"
elif [ "${UNIQUE_NODES}" -lt "${TOTAL_PODS}" ]; then
    log_error "Uwaga: ${TOTAL_PODS} podów ale tylko ${UNIQUE_NODES} unikalnych nodów — naruszenie podAntiAffinity!"
    echo "  → Sprawdź dostępność nodów GPU: oc get nodes -l nvidia.com/gpu.present=true"
else
    log_warn "Liczba podów (${TOTAL_PODS}) mniejsza niż PIPELINE_PARALLEL_SIZE (${PIPELINE_PARALLEL_SIZE})"
fi

# =============================================================================
# Zużycie GPU per pod
# =============================================================================
log_section "Zużycie GPU (nvidia-smi)"

RUNNING_PODS=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    grep "Running" | awk '{print $1}' || true)

if [ -z "${RUNNING_PODS}" ]; then
    log_warn "Brak podów w stanie Running — pomijam sprawdzenie GPU"
else
    for POD in ${RUNNING_PODS}; do
        echo -e "${CYAN}Pod: ${POD}${NC}"
        POD_NODE=$(oc get pod "${POD}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "nieznany")
        echo "  Nod: ${POD_NODE}"

        # Spróbuj uruchomić nvidia-smi w podzie
        GPU_INFO=$(oc exec "${POD}" -n "${NAMESPACE}" -- \
            nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
            --format=csv,noheader,nounits 2>/dev/null || echo "nvidia-smi niedostępne")
        echo "  GPU: ${GPU_INFO}"
    done
fi

# =============================================================================
# Events z ostatnich 10 minut
# =============================================================================
log_section "Events z ostatnich 10 minut"

oc get events -n "${NAMESPACE}" \
    --sort-by='.lastTimestamp' \
    --field-selector 'type!=Normal' \
    2>/dev/null | tail -20 || true

echo ""
log_info "Pełne events: oc get events -n ${NAMESPACE} --sort-by=.lastTimestamp"

} # koniec funkcji print_status

if [ "${WATCH_MODE}" = true ]; then
    log_info "Tryb obserwacji (--watch). Odświeżanie co 30s. Ctrl+C aby zatrzymać."
    while true; do
        clear
        print_status || true
        sleep 30
    done
else
    print_status
fi
