#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Skrypt testowania inference modelu Bielik-11B po deploymencie
# Uruchom po osiągnięciu statusu READY przez LLMInferenceService
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/config.env"

# --- Kolory ANSI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_error()   { echo -e "${RED}[BŁĄD]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

# --- Pobierz URL endpointu z LLMInferenceService ---
log_info "Pobieranie URL endpointu z LLMInferenceService..."
ENDPOINT_URL=$(oc get llminferenceservice bielik-11b-multinode \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.url}' 2>/dev/null || echo "")

if [ -z "${ENDPOINT_URL}" ]; then
    # Próba pobrania przez Route jeśli URL nie jest w statusie
    log_info "URL nie w statusie — szukam Route..."
    ENDPOINT_URL=$(oc get route -n "${NAMESPACE}" \
        -l app=bielik-11b \
        -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    if [ -n "${ENDPOINT_URL}" ]; then
        ENDPOINT_URL="https://${ENDPOINT_URL}"
    fi
fi

if [ -z "${ENDPOINT_URL}" ]; then
    log_error "Nie można pobrać URL endpointu"
    echo "  → Sprawdź: oc get llminferenceservice -n ${NAMESPACE}"
    echo "  → Jeśli używasz port-forward, ustaw: ENDPOINT_URL=http://localhost:8080"
    echo ""
    read -rp "Podaj URL endpointu ręcznie (np. http://localhost:8080): " ENDPOINT_URL
fi

log_info "Endpoint: ${ENDPOINT_URL}"

# Pomocnik do mierzenia czasu requestu curl
timed_curl() {
    local start end elapsed
    start=$(date +%s%N)
    curl "$@"
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    echo -e "\n${YELLOW}⏱  Czas odpowiedzi: ${elapsed} ms${NC}"
}

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}        Test Inference — Bielik-11B-v2.3-Instruct             ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"

# =============================================================================
# TEST 1: GET /v1/models — lista dostępnych modeli
# =============================================================================
log_section "Test 1: Sprawdzenie dostępnych modeli (GET /v1/models)"

echo -e "${CYAN}Request:${NC} GET ${ENDPOINT_URL}/v1/models"
echo "---"
MODELS_RESPONSE=$(timed_curl \
    --silent \
    --fail \
    --max-time 30 \
    "${ENDPOINT_URL}/v1/models" \
    2>&1 || echo '{"error": "request failed"}')

echo "${MODELS_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${MODELS_RESPONSE}"

if echo "${MODELS_RESPONSE}" | grep -q "bielik"; then
    log_success "Model 'bielik-11b' jest widoczny i załadowany"
else
    log_error "Model nie odpowiada lub nazwa jest inna niż oczekiwano"
fi

# =============================================================================
# TEST 2: Pytanie historyczne po polsku
# =============================================================================
log_section "Test 2: Pytanie po polsku — historia (POST /v1/chat/completions)"

PROMPT_2="Kim był Mikołaj Kopernik i z czego zasłynął?"
echo -e "${CYAN}Pytanie:${NC} ${PROMPT_2}"
echo "---"

RESPONSE_2=$(timed_curl \
    --silent \
    --fail \
    --max-time 120 \
    --header "Content-Type: application/json" \
    --data "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {
                \"role\": \"system\",
                \"content\": \"Jesteś pomocnym asystentem AI odpowiadającym w języku polskim. Udzielaj zwięzłych i rzeczowych odpowiedzi.\"
            },
            {
                \"role\": \"user\",
                \"content\": \"${PROMPT_2}\"
            }
        ],
        \"max_tokens\": 256,
        \"temperature\": 0.7
    }" \
    "${ENDPOINT_URL}/v1/chat/completions" \
    2>&1 || echo '{"error": "request failed"}')

# Wyodrębnij treść odpowiedzi
ANSWER_2=$(echo "${RESPONSE_2}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['choices'][0]['message']['content'])
except:
    print('[Nie udało się sparsować odpowiedzi]')
" 2>/dev/null || echo "${RESPONSE_2}")

echo -e "${GREEN}Odpowiedź modelu:${NC}"
echo "${ANSWER_2}"

# =============================================================================
# TEST 3: Pytanie o OpenShift AI
# =============================================================================
log_section "Test 3: Pytanie o OpenShift AI (POST /v1/chat/completions)"

PROMPT_3="Opisz krótko czym jest OpenShift AI i jakie ma zastosowania w przedsiębiorstwach."
echo -e "${CYAN}Pytanie:${NC} ${PROMPT_3}"
echo "---"

RESPONSE_3=$(timed_curl \
    --silent \
    --fail \
    --max-time 120 \
    --header "Content-Type: application/json" \
    --data "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {
                \"role\": \"system\",
                \"content\": \"Jesteś ekspertem od technologii Red Hat i platform AI/ML. Odpowiadaj po polsku, zwięźle i profesjonalnie.\"
            },
            {
                \"role\": \"user\",
                \"content\": \"${PROMPT_3}\"
            }
        ],
        \"max_tokens\": 256,
        \"temperature\": 0.7
    }" \
    "${ENDPOINT_URL}/v1/chat/completions" \
    2>&1 || echo '{"error": "request failed"}')

ANSWER_3=$(echo "${RESPONSE_3}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['choices'][0]['message']['content'])
except:
    print('[Nie udało się sparsować odpowiedzi]')
" 2>/dev/null || echo "${RESPONSE_3}")

echo -e "${GREEN}Odpowiedź modelu:${NC}"
echo "${ANSWER_3}"

# =============================================================================
# Podsumowanie
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅ Testy inference zakończone                               ${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Aby kontynuować testowanie, możesz użyć:"
echo "  curl ${ENDPOINT_URL}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Twoje pytanie\"}]}'"
echo ""
