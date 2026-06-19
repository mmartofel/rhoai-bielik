# Architecture: Bielik-11B Multi-Node Distributed Inference on RHOAI 3.4

> **⚠️ Technology Preview**: llm-d and `LLMInferenceService` are Technology Preview features in RHOAI 3.4. Not supported for production use.

## Overview

This deployment runs **Bielik-11B-v2.3-Instruct-GPTQ** (a Polish LLM by SpeakLeash) across **3 NVIDIA T4 GPU nodes** using **pipeline parallelism**, orchestrated through **llm-d** on Red Hat OpenShift AI 3.4.

The model is stored in a **cluster-local MinIO instance** (S3-compatible), eliminating dependency on HuggingFace availability at serve time. The model is downloaded from HuggingFace exactly once via a Kubernetes Job, then served entirely from within the cluster on all subsequent runs.

---

## Model Specifications

| Property              | Value                                      |
|-----------------------|--------------------------------------------|
| Model                 | Bielik-11B-v2.3-Instruct-GPTQ             |
| Parameters            | ~11 billion                                |
| Quantization          | GPTQ 4-bit                                 |
| Size on disk          | ~7 GB                                      |
| GPU nodes             | 3× g4dn.2xlarge (1× NVIDIA T4 16GB each)  |
| Parallelism strategy  | Pipeline parallel (3 stages), tensor=1    |
| Max context length    | 4096 tokens                                |
| Chat template         | ChatML                                     |

---

## Deployment Flow

```
[One time only]
HuggingFace Hub
    │  hf://speakleash/Bielik-11B-v2.3-Instruct-GPTQ
    ▼
Kubernetes Job (bielik-model-transfer)
    │  huggingface_hub.snapshot_download() → aws s3 sync
    ▼
MinIO  (rhoai-model-registries namespace)
    │  s3://bielik-models/Bielik-11B-v2.3-Instruct-GPTQ/
    ▼
[Every deploy / pod restart — fast, cluster-local]
LLMInferenceService (bielik-11b)
    │  spec.worker → LeaderWorkerSet (3 pods)
    ├── Pod 0 — leader  (pipeline stage 0)  Node A T4
    ├── Pod 1 — worker  (pipeline stage 1)  Node B T4
    └── Pod 2 — worker  (pipeline stage 2)  Node C T4
         └── vLLM  --pipeline-parallel-size=3
```

---

## MinIO — Cluster-Local Model Storage

MinIO runs in the `rhoai-model-registries` namespace and is accessible from any namespace via:

```
http://minio.rhoai-model-registries.svc.cluster.local:9000
```

It is intentionally placed outside `bielik-demo` so it can serve as general-purpose S3 storage for the RHOAI Model Registry and future models beyond Bielik.

| Component | Value |
|-----------|-------|
| Namespace | `rhoai-model-registries` |
| S3 endpoint | `http://minio.rhoai-model-registries.svc.cluster.local:9000` |
| Bucket | `bielik-models` |
| Credentials | `minio` / `minio123` (demo only) |
| Storage | 50Gi PVC (cluster default StorageClass) |

---

## Multi-Node Deployment via LeaderWorkerSet

The `spec.worker` field in `LLMInferenceService` signals llm-d to use a **LeaderWorkerSet** instead of a plain Deployment:

```yaml
spec:
  replicas: 1          # 1 group of N pods
  template:            # leader pod (stage 0)
    containers: [...]
  worker:              # worker pods (stages 1..N)
    containers: [...]
```

With `--pipeline-parallel-size=3`, llm-d creates a 3-pod group:
- **Leader** (stage 0): receives requests, tokenizes, computes first 1/3 of layers
- **Worker 1** (stage 1): receives activations from stage 0, processes middle layers
- **Worker 2** (stage 2): processes final layers, returns output logits

Each pod is scheduled on a different GPU node (anti-affinity is handled by LeaderWorkerSet).

---

## Pipeline vs Tensor Parallelism

**Tensor parallelism** splits individual weight matrices and requires high-bandwidth GPU interconnects (NVLink). It is optimal within a single node.

**Pipeline parallelism** splits the model by layer groups (stages). Communication between stages is activation tensors passed over the network — tolerable on standard Ethernet (AWS ENA 25–100 Gbps).

On **g4dn.2xlarge** nodes (1× T4, no NVLink between nodes), pipeline parallelism is the correct strategy.

---

## Request Flow

```
Client → Inference Gateway (Envoy / maas-default-gateway)
       → LLMInferenceService (llm-d router)
       → vLLM leader pod (stage 0)
          → Activations via TCP → worker pod stage 1
          → Activations via TCP → worker pod stage 2
          → Sampled token returned to leader
       → Response streamed to client
```

---

## S3 Credentials

The `s3-data-connection` Secret in `bielik-demo` contains the MinIO credentials as standard AWS environment variables. Both the leader (`spec.template`) and worker (`spec.worker`) pods receive these credentials via `envFrom`, so all pods can load the model from MinIO at startup.

---

## Network Requirements

- All 3 pods must reach each other on arbitrary TCP ports (vLLM pipeline activation exchange)
- The transfer Job (`bielik-demo` namespace) must reach MinIO (`rhoai-model-registries` namespace) via cross-namespace DNS
- The transfer Job must reach `https://huggingface.co` for the one-time model download
- Verify no NetworkPolicy blocks these paths:

```bash
# Check intra-bielik-demo pod communication
oc get networkpolicy -n bielik-demo

# Check cross-namespace to MinIO
oc get networkpolicy -n rhoai-model-registries
```
