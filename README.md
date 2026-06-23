# Bielik-11B na RHOAI 3.4 — Distributed Inference (multi-node)

> **⚠️ Technology Preview** — llm-d i `LLMInferenceService` to funkcje w wersji Technology Preview w RHOAI 3.4. Nie przeznaczone do zastosowań produkcyjnych.

Repozytorium do wdrożenia polskiego modelu językowego **Bielik-11B-v2.3-Instruct** (projekt [SpeakLeash](https://speakleash.org/)) na klastrze **Red Hat OpenShift AI 3.4** z wykorzystaniem **distributed inference przez llm-d**.

Model jest pobierany z HuggingFace **jednorazowo** i przechowywany w **lokalnym MinIO** (klaster-wewnętrzne S3). Wszystkie kolejne uruchomienia podów ładują model z MinIO — bez zależności od dostępności HuggingFace.

---

## O modelu Bielik

**Bielik-11B-v2.3-Instruct** to polski duży model językowy stworzony przez projekt **SpeakLeash** — inicjatywę open-source budującą polskie zasoby dla AI. Model:
- Ma 11 miliardów parametrów, trenowany na polskich tekstach
- Obsługuje format konwersacyjny (ChatML)
- Wersja GPTQ: skwantyzowany do 4-bit (~7GB na dysku), idealny dla GPU z ograniczonym VRAM
- Licencja: [APACHE 2.0](https://huggingface.co/speakleash/Bielik-11B-v2.3-Instruct-GPTQ)

---

## Wymagania

| Wymaganie                    | Minimalna wersja / liczba      |
|------------------------------|-------------------------------|
| Red Hat OpenShift            | 4.14+                         |
| Red Hat OpenShift AI (RHOAI) | 3.4                           |
| llm-d operator               | włączony w DataScienceCluster |
| Nody GPU                     | 3× g4dn.2xlarge (T4 16GB)    |
| GPU Operator                 | zainstalowany i działający    |
| Node Feature Discovery       | zainstalowany i działający    |
| Konto HuggingFace            | z tokenem dostępu             |
| Narzędzia lokalne            | `oc` CLI, `envsubst`, `curl`  |

### Instalacja narzędzi lokalnych (macOS)
```bash
brew install openshift-cli gettext
```

---

## Quick Start

**1. Sklonuj repozytorium i ustaw token HuggingFace:**
```bash
git clone <url-repozytorium>
cd bielik-rhoai-multinode
# Edytuj config/config.env i uzupełnij HF_TOKEN=hf_xxx...
```

**2. Zaloguj się do klastra OpenShift i uruchom deployment:**
```bash
oc login https://<twoj-klaster>:6443
./scripts/deploy.sh
```

**3. Po osiągnięciu statusu READY — przetestuj model:**
```bash
./manifests/04-test-inference.sh
```

---

## Struktura repozytorium

```
rhoai-bielik/
├── README.md
├── config/
│   ├── config.env                        # Konfiguracja (uzupełnij HF_TOKEN; nie commituj!)
│   └── config.env.example                # Szablon bez tokenu — wersjonowany w git
├── manifests/
│   ├── 00-prerequisites-check.sh         # Weryfikacja prereqs (GPU nody, llm-d, CRDs)
│   ├── 01-namespace.yaml                 # Namespace bielik-demo
│   ├── 02-minio.yaml                     # MinIO S3 w rhoai-model-registries (jednorazowo)
│   ├── 03-hf-secret.yaml.template        # Secret z HF tokenem (dla Job transferu)
│   ├── 04-s3-connection.yaml.template    # Secret z danymi dostępu do MinIO
│   ├── 04-test-inference.sh              # Testy inference po deploymencie
│   ├── 05-accelerator-profile.yaml       # AcceleratorProfile: NVIDIA T4
│   ├── 05-model-transfer-job.yaml.template  # Job: HuggingFace → MinIO (jednorazowo)
│   ├── 06-llminferenceservice.yaml       # LLMInferenceService (spec.parallelism.data: 3)
│   ├── 07-kserve-model-sa.yaml.template  # KServe ServiceAccount + annotowany S3 secret
│   └── 08-pipeline-parallel-config.yaml  # [ZACHOWANY] Custom PP preset — zablokowany bugiem vLLM 0.18.0
├── scripts/
│   ├── deploy.sh                         # Pełny deployment (MinIO → transfer → LLIS → wait)
│   ├── undeploy.sh                       # Usunięcie zasobów
│   ├── status.sh                         # Status deploymentu
│   └── port-forward.sh                   # Lokalny dostęp przez port-forward
└── docs/
    ├── architecture.md                   # Architektura: MinIO, LeaderWorkerSet, data parallelism + historia PP
    └── troubleshooting.md                # Rozwiązywanie typowych problemów
```

---

## Jak to działa — Data Parallelism

Wersja GPTQ (4-bit) modelu Bielik-11B zajmuje ~5,75 GiB VRAM — mieści się na jednej karcie T4 (16 GiB). Zamiast dzielić model między węzły, uruchamiamy **3 niezależne kopie** (data parallelism): każdy węzeł ładuje pełny model i obsługuje osobną porcję zapytań.

```
Request HTTP
     │
     ▼
[llm-d Gateway]
     │
     ▼
[Node A — T4] ← leader (DP rank 0): pełny model + HTTP API :8000
     │               DP Coordinator (ZMQ :5555) rozdziela zapytania
     ├──────────────────────────────────────┐
     ▼                                      ▼
[Node B — T4] ← worker (DP rank 1)   [Node C — T4] ← worker (DP rank 2)
  pełny model, --headless               pełny model, --headless
```

Każde zapytanie jest obsługiwane przez jeden węzeł — brak wymiany aktywacji między węzłami. Dzięki temu przepustowość rośnie 3× liniowo wraz z liczbą węzłów.

**Dlaczego nie pipeline parallelism?**
Pipeline parallelism (`spec.parallelism.pipeline: 3`) był pierwotnym założeniem, ale jest zablokowany bugiem w RHAI vLLM 0.18.0 (`AssertionError: collective_rpc should not be called on follower node`). Szczegóły techniczne i zachowany preset PP: [docs/architecture.md](docs/architecture.md), `manifests/08-pipeline-parallel-config.yaml`.

---

## Zarządzanie deploymentem

```bash
# Sprawdź status deploymentu
./scripts/status.sh

# Obserwuj status w pętli (odświeżanie co 30s)
./scripts/status.sh --watch

# Lokalny dostęp przez port-forward (localhost:8080)
./scripts/port-forward.sh

# Usuń deployment (zachowując namespace)
./scripts/undeploy.sh

# Usuń wszystko łącznie z namespace
./scripts/undeploy.sh --delete-namespace
```

---

## Przykładowe użycie API

Po deploymencie model eksponuje **OpenAI-compatible API**:

```bash
# Pobierz URL endpointu
export ENDPOINT_URL=$(oc get llminferenceservice bielik-11b -n bielik-demo -o jsonpath='{.status.url}')
echo "Endpoint: ${ENDPOINT_URL}"

# Lista załadowanych modeli
curl -k ${ENDPOINT_URL}/v1/models

# Pytanie do modelu
curl -k ${ENDPOINT_URL}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bielik-11b",
    "messages": [
      {"role": "system", "content": "Jesteś pomocnym asystentem AI."},
      {"role": "user", "content": "Czym jest OpenShift AI?"}
    ],
    "max_tokens": 256,
    "temperature": 0.7
  }'
```

---

## Rozwiązywanie problemów

Pełny przewodnik: [docs/troubleshooting.md](docs/troubleshooting.md)

Najczęstsze problemy:
- **Pod `Pending`** → sprawdź nody GPU i resource quotas
- **Job transferu nie kończy się** → sprawdź dostęp do HuggingFace i MinIO (`oc logs job/bielik-model-transfer -n bielik-demo`)
- **MinIO niedostępny** → sprawdź pody w `rhoai-model-registries` namespace
- **Workers nie łączą się z DP Coordinator** → sprawdź port 5555 między podami (`oc exec ... -- nc -zv <leader-ip> 5555`)
- **OOM na T4** → zmniejsz `MAX_MODEL_LEN` lub `GPU_MEMORY_UTILIZATION`

---

## Linki

- [SpeakLeash — projekt Bielik](https://speakleash.org/)
- [Model na HuggingFace](https://huggingface.co/speakleash/Bielik-11B-v2.3-Instruct-GPTQ)
- [Red Hat OpenShift AI dokumentacja](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [llm-d — projekt distributed inference](https://github.com/llm-d/llm-d)
- [vLLM distributed inference](https://docs.vllm.ai/en/latest/serving/distributed_serving.html)
