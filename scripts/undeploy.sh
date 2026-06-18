#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Skrypt usunięcia deploymentu Bielik-11B z klastra RHOAI
# Użycie: ./scripts/undeploy.sh [--delete-namespace]
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

DELETE_NAMESPACE=false
for arg in "$@"; do
    [ "${arg}" = "--delete-namespace" ] && DELETE_NAMESPACE=true
done

echo ""
echo -e "${BOLD}${RED}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  Usuwanie deploymentu Bielik-11B z RHOAI                     ${NC}"
echo -e "${BOLD}${RED}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Potwierdzenie od użytkownika
log_warn "Namespace: ${NAMESPACE}"
log_warn "Zostaną usunięte: LLMInferenceService, Secret hf-token"
echo ""
read -rp "Czy na pewno chcesz usunąć deployment? [t/N]: " CONFIRM
case "${CONFIRM:-N}" in
    [Tt]*) ;;
    *) echo "Anulowano."; exit 0 ;;
esac

# --- Usunięcie LLMInferenceService ---
log_info "Usuwanie LLMInferenceService 'bielik-11b-multinode'..."
if oc get llminferenceservice bielik-11b-multinode -n "${NAMESPACE}" &>/dev/null; then
    oc delete llminferenceservice bielik-11b-multinode -n "${NAMESPACE}"
    log_success "LLMInferenceService usunięty"
else
    log_warn "LLMInferenceService 'bielik-11b-multinode' nie istnieje — pomijam"
fi

# --- Usunięcie Secret ---
log_info "Usuwanie Secret 'hf-token'..."
if oc get secret hf-token -n "${NAMESPACE}" &>/dev/null; then
    oc delete secret hf-token -n "${NAMESPACE}"
    log_success "Secret 'hf-token' usunięty"
else
    log_warn "Secret 'hf-token' nie istnieje — pomijam"
fi

# --- Opcjonalne usunięcie namespace ---
if [ "${DELETE_NAMESPACE}" = false ]; then
    echo ""
    read -rp "Czy usunąć namespace '${NAMESPACE}' (usuwa WSZYSTKIE zasoby)? [t/N]: " DEL_NS
    case "${DEL_NS:-N}" in
        [Tt]*) DELETE_NAMESPACE=true ;;
    esac
fi

if [ "${DELETE_NAMESPACE}" = true ]; then
    log_info "Usuwanie namespace '${NAMESPACE}'..."
    if oc get namespace "${NAMESPACE}" &>/dev/null; then
        oc delete namespace "${NAMESPACE}"
        log_success "Namespace '${NAMESPACE}' usunięty"
    else
        log_warn "Namespace '${NAMESPACE}' nie istnieje — pomijam"
    fi
else
    log_info "Namespace '${NAMESPACE}' zachowany"
fi

# Usuń wygenerowany secret file jeśli istnieje
GENERATED_SECRET="${REPO_DIR}/manifests/02-hf-secret.yaml"
if [ -f "${GENERATED_SECRET}" ]; then
    rm -f "${GENERATED_SECRET}"
    log_success "Usunięto wygenerowany plik ${GENERATED_SECRET}"
fi

echo ""
log_success "Undeployment zakończony"
