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
│   └── 06-llminferenceservice.yaml       # LLMInferenceService (spec.worker → multi-node)
├── scripts/
│   ├── deploy.sh                         # Pełny deployment (MinIO → transfer → LLIS → wait)
│   ├── undeploy.sh                       # Usunięcie zasobów
│   ├── status.sh                         # Status deploymentu
│   └── port-forward.sh                   # Lokalny dostęp przez port-forward
└── docs/
    ├── architecture.md                   # Architektura: MinIO, LeaderWorkerSet, pipeline parallel
    └── troubleshooting.md                # Rozwiązywanie typowych problemów
```

---

## Jak to działa — Pipeline Parallelism

Model Bielik-11B jest za duży, aby zmieścić się na jednej karcie T4 (16GB VRAM) bez kwantyzacji lub podziału. Używamy **pipeline parallelism**: model jest podzielony na 3 grupy warstw (stages), każda działająca na osobnym nodzie GPU.

```
Request HTTP
     │
     ▼
[llm-d Gateway]
     │
     ▼
[Node A — T4] → Stage 0 (warstwy 0–12)
     │ aktywacje (TCP)
     ▼
[Node B — T4] → Stage 1 (warstwy 13–24)
     │ aktywacje (TCP)
     ▼
[Node C — T4] → Stage 2 (warstwy 25–40 + głowa LM)
     │ tokeny
     ▼
Response JSON
```

**Dlaczego pipeline, nie tensor parallelism?**
Tensor parallelism wymaga szybkich połączeń NVLink między GPU. Instancje g4dn.2xlarge mają po jednej T4 i nie są połączone NVLinkiemm — pipeline parallelism przez standardową sieć TCP (AWS ENA) jest właściwym wyborem dla tej topologii.

Szczegóły: [docs/architecture.md](docs/architecture.md)

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
# Lista załadowanych modeli
curl ${ENDPOINT_URL}/v1/models

# Pytanie do modelu
curl ${ENDPOINT_URL}/v1/chat/completions \
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
- **Ray nie startuje** → sprawdź NetworkPolicy między podami
- **OOM na T4** → zmniejsz `MAX_MODEL_LEN` lub `GPU_MEMORY_UTILIZATION`

---

## Linki

- [SpeakLeash — projekt Bielik](https://speakleash.org/)
- [Model na HuggingFace](https://huggingface.co/speakleash/Bielik-11B-v2.3-Instruct-GPTQ)
- [Red Hat OpenShift AI dokumentacja](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [llm-d — projekt distributed inference](https://github.com/llm-d/llm-d)
- [vLLM distributed inference](https://docs.vllm.ai/en/latest/serving/distributed_serving.html)
# rhoai-bielik
