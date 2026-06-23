# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for deploying **Bielik-11B-v2.3-Instruct-GPTQ** (Polish LLM by SpeakLeash) on **Red Hat OpenShift AI 3.4** using **llm-d distributed inference**. No application code — only Kubernetes manifests, shell scripts, and deployment tooling.

## Prerequisites (local machine)

```bash
brew install openshift-cli gettext   # oc + envsubst
oc login https://<cluster>:6443
```

## Deployment commands

```bash
# Full deployment (MinIO → model transfer → LLMInferenceService → wait for READY)
./scripts/deploy.sh

# Skip prerequisites check (already verified)
./scripts/deploy.sh --skip-prereqs

# Skip model transfer (model already in MinIO from a previous run)
./scripts/deploy.sh --skip-transfer

# Check deployment status
./scripts/status.sh
./scripts/status.sh --watch          # refreshes every 30s

# Local access via port-forward (localhost:8080)
./scripts/port-forward.sh

# Run inference tests against the live endpoint
./manifests/04-test-inference.sh

# Tear down (keep namespace)
./scripts/undeploy.sh

# Tear down everything including namespace
./scripts/undeploy.sh --delete-namespace
```

## Configuration

Copy `config/config.env.example` → `config/config.env` and set `HF_TOKEN`. The `config/config.env` file is gitignored. Template files (`*.yaml.template`) are rendered via `envsubst` with explicit variable lists in `scripts/deploy.sh` — add new variables to both the template and the `envsubst` call.

## Architecture

### Data flow

```
HuggingFace (once) → Kubernetes Job → MinIO (rhoai-model-registries ns) → LLMInferenceService pods
```

Subsequent pod restarts load the model from cluster-local MinIO (~37s per pod), with no HuggingFace dependency.

### Multi-node setup

`spec.parallelism.data: 3` + `dataLocal: 1` in `manifests/06-llminferenceservice.yaml` activates llm-d's built-in data-parallel preset (`v3-4-0-kserve-config-llm-worker-data-parallel`), which creates a **LeaderWorkerSet** of 3 pods across 3 GPU nodes. The preset injects all vLLM `--data-parallel-*` flags automatically. Inter-node coordination uses ZMQ RPC on TCP port 5555.

### Namespaces

| Resource | Namespace |
|---|---|
| LLMInferenceService, transfer Job | `bielik-demo` |
| MinIO S3 storage | `rhoai-model-registries` |
| llm-d controller, preset ConfigMaps | `redhat-ods-applications` |

### Request path

```
Client → Inference Gateway (Envoy) → llm-d router → vLLM API Server (leader :8000)
       → DP Coordinator (ZMQ :5555) → least-loaded worker (rank 0/1/2) → response
```

## Critical constraints

**LLMInferenceService spec structure (v1alpha2):** Both leader and worker pods are configured under `spec.template.containers` and `spec.worker.containers` respectively — these are **flat container arrays**, not `spec.containers`. Placing args/resources/envFrom at the wrong level silently discards them without error.

**CPU requests must be `"1"`** — the g4dn.2xlarge nodes run at 79-94% CPU utilization. Higher CPU requests cause pods to stay `Pending` with no available node.

**Pipeline parallelism is blocked** — `spec.parallelism.pipeline: 3` hits an `AssertionError: collective_rpc should not be called on follower node` bug in vLLM 0.18.0 (bundled with RHOAI 3.4). The GPTQ 4-bit model fits in a single T4 (5.75 GiB of 16 GiB), so data parallelism is correct anyway. The abandoned PP preset is preserved in `manifests/08-pipeline-parallel-config.yaml` for reference.

**`envFrom` must reference `s3-data-connection`** in both `spec.template.containers` and `spec.worker.containers` — both the leader and worker pods need S3 credentials for the KServe storage-initializer init container.

## Playground (llama-stack)

`manifests/09-playground.yaml` deploys a `LlamaStackDistribution` (managed by the llama-stack-operator) that connects to the `LLMInferenceService` and surfaces Bielik-11B in RHOAI Gen AI studio → Playground.

**Critical:** `VLLM_MAX_TOKENS` must be less than `--max-model-len` (4096). The current value is `1024`, leaving 3072 tokens for the prompt + context. Setting it to 4096 causes a 400 error on every call ("0 input tokens available").

Apply or re-apply after changes: `oc apply -f manifests/09-playground.yaml` — the operator rolls the pod without touching the `LLMInferenceService`.

## RHOAI UI visibility

`LLMInferenceService` (llm-d) objects are **only visible in AI hub → Models → Deployments**, not in the per-project "Deployments" tab. The project-level tab queries for standard KServe `InferenceService` resources; llm-d deployments are excluded by design in RHOAI 3.4 (Tech Preview gap). The "Select the model serving type" prompt in Projects → bielik-demo → Deployments is expected and harmless.

## Pod names after deployment

| Pod | Role |
|---|---|
| `bielik-11b-kserve-mn-0` | Leader (DP rank 0) — serves HTTP API |
| `bielik-11b-kserve-mn-0-1` | Worker (DP rank 1) — headless |
| `bielik-11b-kserve-mn-0-2` | Worker (DP rank 2) — headless |

## Quick diagnostics

```bash
# Overall status
oc describe llminferenceservice bielik-11b -n bielik-demo

# Pod logs
oc logs -f bielik-11b-kserve-mn-0 -n bielik-demo --tail=50
oc logs -n bielik-demo --selector=leaderworkerset.sigs.k8s.io/name=bielik-11b-kserve-mn --timestamps --tail=50

# Confirm DP coordinator is up (leader log)
oc logs bielik-11b-kserve-mn-0 -n bielik-demo | grep -i "DP Coordinator\|READY"

# Test ZMQ connectivity from worker to leader
LEADER_IP=$(oc get pod bielik-11b-kserve-mn-0 -n bielik-demo -o jsonpath='{.status.podIP}')
oc exec bielik-11b-kserve-mn-0-1 -n bielik-demo -- nc -zv ${LEADER_IP} 5555

# Get endpoint URL
oc get llminferenceservice bielik-11b -n bielik-demo -o jsonpath='{.status.url}'
```

See `docs/troubleshooting.md` for full diagnosis procedures for common failure modes (Pending pods, OOM, DP coordinator not ready, transfer Job failures).
