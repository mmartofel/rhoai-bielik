# Architecture: Bielik-11B Multi-Node Distributed Inference on RHOAI 3.4

> **⚠️ Technology Preview**: llm-d and `LLMInferenceService` are Technology Preview features in RHOAI 3.4. Not supported for production use.

## Overview

This deployment runs **Bielik-11B-v2.3-Instruct-GPTQ** (a Polish LLM by SpeakLeash) across **3 NVIDIA T4 GPU nodes** using **pipeline parallelism** coordinated by Ray, orchestrated through the **llm-d** operator on Red Hat OpenShift AI 3.4.

---

## Model Specifications

| Property              | Value                                      |
|-----------------------|--------------------------------------------|
| Model                 | Bielik-11B-v2.3-Instruct-GPTQ             |
| Parameters            | ~11 billion                                |
| Quantization          | GPTQ 4-bit                                 |
| Estimated size        | ~7 GB on disk                              |
| VRAM per node (stage) | ~7–8 GB (fits within T4 16GB)              |
| Total VRAM used       | ~21–24 GB across 3× T4 (48 GB total)      |
| GPU node type         | g4dn.2xlarge (1× NVIDIA T4 16GB)          |
| Parallelism strategy  | Pipeline parallel (3 stages), tensor=1    |
| Max context length    | 4096 tokens                                |
| Chat template         | ChatML                                     |

---

## Why Pipeline Parallelism (Not Tensor Parallelism)?

**Tensor parallelism** splits individual weight matrices across multiple GPUs that must communicate synchronously via high-bandwidth interconnects (NVLink, NVSwitch). It is optimal when GPUs share the same host or are connected via fast fabric.

**Pipeline parallelism** splits the model *by layer groups* (stages), where each stage processes a micro-batch sequentially and passes activations to the next stage. Communication is between stages, not within a weight operation — making it far more tolerant of inter-node network latency (100Gbps Ethernet on AWS is sufficient).

On **g4dn.2xlarge** instances:
- Each node has exactly **1× T4** (no NVLink between nodes)
- Network is AWS ENA (25–100 Gbps)
- T4 has no NVLink port — tensor parallelism across nodes would be extremely slow
- Pipeline parallelism via Ray is the correct strategy for this topology

```
Tensor Parallel (wrong for this setup):
  Node A GPU ←─── NVLink ───→ Node B GPU   ← requires fast interconnect
              (not available between AWS instances)

Pipeline Parallel (correct for this setup):
  Node A GPU → activations → Node B GPU → activations → Node C GPU
              (standard network, tolerable latency)
```

---

## Request Flow Diagram

```
                          ┌─────────────────────────────────────────────┐
  Client                  │          OpenShift Cluster                   │
  ──────                  │                                              │
    │                     │  ┌──────────────┐                           │
    │  HTTP POST          │  │  Inference   │  (llm-d Gateway/Router)   │
    │  /v1/chat/          │  │  Gateway     │                           │
    │  completions  ──────┼─▶│  (Envoy)     │                           │
    │                     │  └──────┬───────┘                           │
    │                     │         │ route to LLMInferenceService       │
    │                     │  ┌──────▼───────────────────────────────┐   │
    │                     │  │    LLMInferenceService               │   │
    │                     │  │    bielik-11b-multinode              │   │
    │                     │  │    (llm-d scheduler)                 │   │
    │                     │  └──────┬───────────────────────────────┘   │
    │                     │         │ dispatch to Ray pipeline            │
    │                     │         │                                     │
    │                     │  ┌──────▼──────────────────────────────┐    │
    │                     │  │          Ray Cluster (3 workers)    │    │
    │                     │  │                                     │    │
    │                     │  │  ┌────────────┐                     │    │
    │                     │  │  │  Node A    │  Stage 0            │    │
    │                     │  │  │  g4dn.2xl  │  Layers 0–12       │    │
    │                     │  │  │  T4 16GB   │  (embed + first ¹⁄₃)│   │
    │                     │  │  └─────┬──────┘                     │    │
    │                     │  │        │ activations (TCP/IP)        │    │
    │                     │  │  ┌─────▼──────┐                     │    │
    │                     │  │  │  Node B    │  Stage 1            │    │
    │                     │  │  │  g4dn.2xl  │  Layers 13–24      │    │
    │                     │  │  │  T4 16GB   │  (middle ¹⁄₃)       │   │
    │                     │  │  └─────┬──────┘                     │    │
    │                     │  │        │ activations (TCP/IP)        │    │
    │                     │  │  ┌─────▼──────┐                     │    │
    │                     │  │  │  Node C    │  Stage 2            │    │
    │                     │  │  │  g4dn.2xl  │  Layers 25–40      │    │
    │                     │  │  │  T4 16GB   │  (last ¹⁄₃ + head) │   │
    │                     │  │  └─────┬──────┘                     │    │
    │                     │  │        │ output logits               │    │
    │                     │  └────────┼────────────────────────────┘    │
    │                     │           │ sampled tokens                   │
    │◀────────────────────┼───────────┘                                 │
    │  JSON response      │                                              │
                          └─────────────────────────────────────────────┘
```

---

## How Ray Manages Inter-Node Communication

Ray is a distributed computing framework that llm-d uses as the execution backend for pipeline parallelism (`--distributed-executor-backend ray`).

**Ray cluster setup** (managed by llm-d):
1. One pod acts as **Ray head node** — coordinates scheduling and owns the pipeline driver
2. Other pods act as **Ray worker nodes** — each hosts one pipeline stage
3. Ray uses gRPC for control plane, and NCCL/TCP for tensor communication between stages

**Key environment variables**:
- `VLLM_WORKER_MULTIPROC_METHOD=spawn` — required for CUDA multiprocessing (avoids fork-safety issues)
- `NCCL_DEBUG=WARN` — reduces NCCL logging noise; set to `INFO` to debug communication issues

**What happens during a request**:
1. vLLM tokenizes the input on the driver (Stage 0 pod)
2. Embeddings are computed on Stage 0 (Node A T4)
3. Activations are sent via TCP to Stage 1 (Node B T4)
4. Stage 1 processes its layers, sends activations to Stage 2 (Node C T4)
5. Stage 2 computes logits and returns the sampled token to the driver
6. This repeats for each generated token (autoregressive decoding)

**KV Cache**: Each stage keeps its own KV cache in local GPU memory. With 3 stages and 4096 max context, each T4 stores the KV cache for its own layers only.

---

## llm-d Components

```
┌─────────────────────────────────────────────────────────────────┐
│                    DataScienceCluster                           │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  llm-d Operator  │  │  KServe CRD      │                    │
│  │  (controller)    │  │  LLMInference-   │                    │
│  │                  │  │  Service         │                    │
│  └────────┬─────────┘  └────────┬─────────┘                    │
│           │ reconciles          │ watches                       │
│           ▼                     ▼                               │
│  ┌──────────────────────────────────────────────┐              │
│  │  llm-d Scheduler + Gateway + Router          │              │
│  │  (manages pod lifecycle, routing, scaling)   │              │
│  └──────────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Network Requirements

For Ray inter-node communication to work, pods must be able to reach each other on arbitrary TCP ports. Verify that no NetworkPolicy blocks pod-to-pod traffic within the `bielik-demo` namespace.

```bash
# Check for restrictive NetworkPolicies
oc get networkpolicy -n bielik-demo

# If blocked, allow intra-namespace traffic:
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: bielik-demo
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
EOF
```
