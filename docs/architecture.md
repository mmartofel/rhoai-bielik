# Architecture: Bielik-11B Multi-Node Inference on RHOAI 3.4

> **⚠️ Technology Preview**: llm-d and `LLMInferenceService` are Technology Preview features in RHOAI 3.4. Not supported for production use.

## Overview

This deployment runs **Bielik-11B-v2.3-Instruct-GPTQ** (a Polish LLM by SpeakLeash) across **3 NVIDIA T4 GPU nodes** using **data parallelism**, orchestrated through **llm-d** on Red Hat OpenShift AI 3.4.

The model is stored in a **cluster-local MinIO instance** (S3-compatible), eliminating dependency on HuggingFace availability at serve time. The model is downloaded from HuggingFace exactly once via a Kubernetes Job, then served entirely from within the cluster on all subsequent runs.

---

## Model Specifications

| Property              | Value                                       |
|-----------------------|---------------------------------------------|
| Model                 | Bielik-11B-v2.3-Instruct-GPTQ              |
| Parameters            | ~11 billion                                 |
| Quantization          | GPTQ 4-bit (gptq_marlin kernel)             |
| Size on disk          | ~7 GB                                       |
| GPU memory per node   | 5.75 GiB (fits in T4 16 GiB)               |
| GPU nodes             | 3× g4dn.2xlarge (1× NVIDIA T4 16 GiB each) |
| Parallelism strategy  | Data parallel (3 workers, 3× throughput)    |
| KV cache per node     | 33,392 tokens                               |
| Max context length    | 4096 tokens                                 |

---

## Deployment Flow

```
[One time only]
HuggingFace Hub
    │  speakleash/Bielik-11B-v2.3-Instruct-GPTQ
    ▼
Kubernetes Job (bielik-model-transfer)
    │  huggingface_hub.snapshot_download() → aws s3 sync
    ▼
MinIO  (rhoai-model-registries namespace)
    │  s3://bielik-models/Bielik-11B-v2.3-Instruct-GPTQ/
    ▼
[Every deploy / pod restart — ~37s from cluster-local MinIO]
LLMInferenceService (bielik-11b)
    │  spec.parallelism.data: 3  →  LeaderWorkerSet (3 pods)
    │
    ├── Pod 0 — leader  (DP rank 0)  Node A T4  — full model + HTTP API on :8000
    │       └── DP Coordinator (ZMQ) — distributes requests to all 3 workers
    ├── Pod 1 — worker  (DP rank 1)  Node B T4  — full model + --headless
    └── Pod 2 — worker  (DP rank 2)  Node C T4  — full model + --headless
```

---

## MinIO — Cluster-Local Model Storage

MinIO runs in the `rhoai-model-registries` namespace and is accessible from any namespace via:

```
http://minio.rhoai-model-registries.svc.cluster.local:9000
```

It is intentionally placed outside `bielik-demo` so it can serve as general-purpose S3 storage for the RHOAI Model Registry and future models beyond Bielik.

| Component   | Value                                                          |
|-------------|----------------------------------------------------------------|
| Namespace   | `rhoai-model-registries`                                       |
| S3 endpoint | `http://minio.rhoai-model-registries.svc.cluster.local:9000`  |
| Bucket      | `bielik-models`                                                |
| Credentials | `minio` / `minio123` (demo only)                               |
| Storage     | 50 GiB PVC (cluster default StorageClass)                      |

---

## Multi-Node Deployment via LeaderWorkerSet

`spec.parallelism.data: 3` with `dataLocal: 1` tells llm-d to use the built-in RHOAI 3.4 data-parallel preset (`v3-4-0-kserve-config-llm-worker-data-parallel`), which creates a **LeaderWorkerSet** of 3 pods:

```yaml
spec:
  parallelism:
    data: 3        # total DP workers across all nodes
    dataLocal: 1   # GPUs per node (required when data is set)
```

The preset injects these vLLM flags automatically:

| Pod     | Key flags injected by preset                                              |
|---------|---------------------------------------------------------------------------|
| Leader  | `--data-parallel-size 3 --data-parallel-start-rank 0 --data-parallel-address <leader-ip> --data-parallel-rpc-port 5555 --api-server-count 8` |
| Worker 1 | `--data-parallel-size 3 --data-parallel-start-rank 1 --data-parallel-address <leader-ip> --headless` |
| Worker 2 | `--data-parallel-size 3 --data-parallel-start-rank 2 --data-parallel-address <leader-ip> --headless` |

Each pod runs an independent, complete vLLM engine. The **DP Coordinator** process on the leader registers all 3 workers, then signals READY. The leader's 8 API server processes then distribute incoming requests across the 3 engines via ZMQ.

---

## Request Flow

```
Client
  → Inference Gateway (Envoy / maas-default-gateway)
  → LLMInferenceService router (llm-d)
  → vLLM API Server (leader pod :8000)
      → DP Coordinator (ZMQ RPC :5555)
          → Route request to least-loaded DP worker (rank 0, 1, or 2)
          → Worker generates tokens independently
          → Response returned to API Server
  → Client
```

Each request is handled entirely by one worker — there is no inter-node activation exchange. This makes data parallelism well-suited for standard Ethernet (ENA 25 Gbps on g4dn.2xlarge).

---

## Why Not Pipeline Parallelism?

The original design intent was to use **pipeline parallelism** (`spec.parallelism.pipeline: 3`) to split the model's layers across 3 nodes. This would allow serving a model that is too large for a single GPU's VRAM.

However, RHAI vLLM 0.18.0 (the version bundled with RHOAI 3.4) has a bug in the multi-node pipeline-parallel code path:

```
AssertionError: collective_rpc should not be called on follower node
```

**Root cause:** vLLM computes `node_rank_within_dp = node_rank % nnodes_within_dp`. For a 3-node PP setup without explicit DP configuration, `nnodes_within_dp = 3`, giving worker nodes `node_rank_within_dp = 1` or `2`. The `MultiprocExecutor` only initializes `rpc_broadcast_mq` when `node_rank_within_dp == 0`, so worker nodes crash when `collective_rpc` is called and the queue is `None`.

`--distributed-executor-backend=ray` would bypass this path but Ray is not installed in the RHAI container image.

**Practical note:** With GPTQ 4-bit quantization, Bielik-11B loads in only 5.75 GiB per node — well within the T4's 16 GiB. Pipeline parallelism would only be strictly necessary for a non-quantized FP16 model (~22 GiB), which exceeds the T4's capacity. For the GPTQ variant, data parallelism is the correct and supported approach.

---

## S3 Credentials

The `s3-data-connection` Secret in `bielik-demo` contains the MinIO credentials as standard AWS environment variables. Both the leader (`spec.template`) and worker (`spec.worker`) pods receive these credentials via `envFrom`, so all pods can load the model from MinIO at startup via the KServe storage-initializer init container.

---

## Network Requirements

- All 3 pods must reach the leader on TCP port **5555** (DP Coordinator ZMQ RPC)
- The transfer Job (`bielik-demo`) must reach MinIO (`rhoai-model-registries`) via cross-namespace DNS
- The transfer Job must reach `https://huggingface.co` for the one-time model download

```bash
# Check for NetworkPolicy restrictions
oc get networkpolicy -n bielik-demo
oc get networkpolicy -n rhoai-model-registries
```
