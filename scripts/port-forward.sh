#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Skrypt uruchamiający port-forward dla lokalnego dostępu do Bielik-11B
# Użycie: ./scripts/port-forward.sh [LOCAL_PORT]
# Domyślny lokalny port: 8080
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
log_error()   { echo -e "${RED}[BŁĄD]${NC} $*" >&2; }

LOCAL_PORT="${1:-8080}"

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Port-Forward: Bielik-11B → localhost:${LOCAL_PORT}           ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- Znajdź Service stworzony przez llm-d ---
log_info "Wyszukiwanie Service dla 'bielik-11b' w namespace '${NAMESPACE}'..."

# llm-d tworzy service z różnymi konwencjami nazw — sprawdź kilka wariantów
SERVICE_NAME=""
for LABEL_SELECTOR in \
    "app=bielik-11b" \
    "llm-d.ai/inferenceservice=bielik-11b" \
    "serving.kserve.io/inferenceservice=bielik-11b"; do

    FOUND=$(oc get service -n "${NAMESPACE}" \
        -l "${LABEL_SELECTOR}" \
        --no-headers 2>/dev/null | awk '{print $1}' | head -1 || echo "")
    if [ -n "${FOUND}" ]; then
        SERVICE_NAME="${FOUND}"
        log_success "Znaleziono Service: '${SERVICE_NAME}' (przez label: ${LABEL_SELECTOR})"
        break
    fi
done

# Fallback: pokaż wszystkie services i pozwól użytkownikowi wybrać
if [ -z "${SERVICE_NAME}" ]; then
    log_warn "Nie znaleziono Service automatycznie. Dostępne Services w namespace '${NAMESPACE}':"
    echo ""
    oc get service -n "${NAMESPACE}" 2>/dev/null || true
    echo ""
    read -rp "Podaj nazwę Service do port-forward: " SERVICE_NAME
fi

if [ -z "${SERVICE_NAME}" ]; then
    log_error "Brak nazwy Service — nie można uruchomić port-forward"
    exit 1
fi

# Sprawdź port Service
SERVICE_PORT=$(oc get service "${SERVICE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")

log_info "Service: ${SERVICE_NAME} (port: ${SERVICE_PORT})"
log_info "Uruchamiam: oc port-forward service/${SERVICE_NAME} ${LOCAL_PORT}:${SERVICE_PORT} -n ${NAMESPACE}"

echo ""
echo -e "${BOLD}━━━ Po uruchomieniu port-forward użyj poniższych komend: ━━━${NC}"
echo ""
echo -e "${CYAN}# Lista modeli:${NC}"
echo "  curl http://localhost:${LOCAL_PORT}/v1/models | python3 -m json.tool"
echo ""
echo -e "${CYAN}# Pytanie do modelu:${NC}"
echo "  curl http://localhost:${LOCAL_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{"
echo "      \"model\": \"${MODEL_NAME}\","
echo "      \"messages\": ["
echo "        {\"role\": \"system\", \"content\": \"Jesteś pomocnym asystentem AI.\"},"
echo "        {\"role\": \"user\", \"content\": \"Czym jest język polski?\"}"
echo "      ],"
echo "      \"max_tokens\": 256"
echo "    }' | python3 -m json.tool"
echo ""
echo -e "${CYAN}# Sprawdzenie zdrowia:${NC}"
echo "  curl http://localhost:${LOCAL_PORT}/health"
echo ""
echo -e "${YELLOW}Ctrl+C aby zatrzymać port-forward${NC}"
echo ""

# Uruchom port-forward (blokujące)
exec oc port-forward \
    "service/${SERVICE_NAME}" \
    "${LOCAL_PORT}:${SERVICE_PORT}" \
    -n "${NAMESPACE}"
