# Troubleshooting Guide: Bielik-11B on RHOAI 3.4

## Quick Diagnostics

```bash
# One-shot status overview
./scripts/status.sh

# Follow events live
oc get events -n bielik-demo --sort-by=.lastTimestamp -w

# Describe the LLMInferenceService
oc describe llminferenceservice bielik-11b -n bielik-demo

# Pod logs (replace POD_NAME)
oc logs -f POD_NAME -n bielik-demo --tail=100
```

---

## Problem: Pod stuck in `Pending`

**Symptoms**: `oc get pods -n bielik-demo` shows pods in `Pending` state for more than 5 minutes.

**Cause 1: No schedulable GPU nodes**
```bash
# Check available GPU nodes
oc get nodes -l 'nvidia.com/gpu.present=true'

# Check if nodes have taints that block scheduling
oc describe nodes -l 'nvidia.com/gpu.present=true' | grep -A5 Taints

# If nodes are tainted, add tolerations to the LLMInferenceService spec:
# spec.template.spec.tolerations:
# - key: "nvidia.com/gpu"
#   operator: "Exists"
#   effect: "NoSchedule"
```

**Cause 2: Resource quota exceeded**
```bash
# Check resource quotas in namespace
oc get resourcequota -n bielik-demo
oc describe resourcequota -n bielik-demo

# Check if enough GPU resources exist in cluster
oc describe nodes -l 'nvidia.com/gpu.present=true' | grep -A3 'Allocated resources'
```

**Cause 3: podAntiAffinity cannot be satisfied**
```bash
# If there are fewer GPU nodes than PIPELINE_PARALLEL_SIZE, pods can't all land on different nodes
# Count GPU nodes:
oc get nodes -l 'nvidia.com/gpu.present=true' --no-headers | wc -l

# Solution: reduce PIPELINE_PARALLEL_SIZE in config/config.env and redeploy
```

**Cause 4: GPU Operator not labeling nodes**
```bash
# Verify NFD and GPU Operator pods are Running
oc get pods -n nvidia-gpu-operator
oc get pods -A | grep -i nfd

# Force NFD re-detection:
oc rollout restart daemonset -n nvidia-gpu-operator node-feature-discovery-worker
```

---

## Problem: Model download fails (HuggingFace error)

**Symptoms**: Pod starts but logs show HTTP 401/403 from HuggingFace, or model download times out.

**Check 1: Verify HF_TOKEN**
```bash
# Check the secret exists and has a token
oc get secret huggingface-token -n bielik-demo -o jsonpath='{.data.HF_TOKEN}' | base64 -d | wc -c
# Should print a non-zero length

# Test token validity (from local machine):
curl -H "Authorization: Bearer YOUR_TOKEN" https://huggingface.co/api/whoami
```

**Check 2: Network egress from pods**
```bash
# Test connectivity from a pod (if wget/curl is available in the image)
oc exec POD_NAME -n bielik-demo -- curl -I https://huggingface.co

# Check EgressNetworkPolicy (OpenShift-specific)
oc get egressnetworkpolicy -n bielik-demo
```

**Check 3: Proxy configuration**
```bash
# If the cluster uses an HTTP proxy, add to LLMInferenceService env:
# - name: HTTPS_PROXY
#   value: "http://proxy.example.com:3128"
# - name: NO_PROXY
#   value: "localhost,127.0.0.1,.cluster.local"
```

---

## Problem: Ray cannot coordinate between pods

**Symptoms**: vLLM logs show Ray connection errors, pipeline stages fail to initialize, errors like `ray.exceptions.RayConnectionError` or `Failed to connect to Ray cluster`.

**Check 1: Network policy blocking inter-pod traffic**
```bash
# Check if NetworkPolicy is restricting pod-to-pod traffic
oc get networkpolicy -n bielik-demo
oc describe networkpolicy -n bielik-demo

# Allow intra-namespace traffic (see architecture.md for the full NetworkPolicy manifest)
```

**Check 2: Ray head pod logs**
```bash
# Find the ray head pod (usually the first pod or the one with "head" in the name)
oc get pods -n bielik-demo -o wide

# Check Ray head logs for initialization errors
oc logs POD_NAME -n bielik-demo | grep -i "ray\|NCCL\|connection"

# Increase NCCL verbosity for deeper diagnosis:
# Add env var to LLMInferenceService: NCCL_DEBUG=INFO
```

**Check 3: Ray port availability**
```bash
# Ray uses ports 6379 (Redis/GCS), 8265 (dashboard), 10001+ (workers)
# Verify pods can reach each other:
oc exec POD_A -n bielik-demo -- nc -zv POD_B_IP 6379
```

---

## Problem: OOM (Out of Memory) on T4

**Symptoms**: Pod crashes with `CUDA out of memory` error, or nvidia-smi shows memory near 100%.

**Mitigation 1: Reduce max sequence length**
```bash
# Edit config/config.env:
MAX_MODEL_LEN=2048   # down from 4096

# Or directly in manifests/06-llminferenceservice.yaml, change:
# --max-model-len 2048
```

**Mitigation 2: Reduce GPU memory utilization**
```bash
# Edit config/config.env:
GPU_MEMORY_UTILIZATION=0.75   # down from 0.85
```

**Mitigation 3: Check for memory leaks between requests**
```bash
# Monitor GPU memory in real-time
oc exec POD_NAME -n bielik-demo -- nvidia-smi dmon -s m -d 5
```

**Mitigation 4: Verify GPTQ quantization is active**
```bash
# Check logs for quantization confirmation
oc logs POD_NAME -n bielik-demo | grep -i "gptq\|quantiz"
# Should see: "Loading model weights with GPTQ quantization"
```

---

## Problem: LLMInferenceService stuck in NotReady

**Symptoms**: `oc get llminferenceservice` shows Ready=False, status doesn't change after 15+ minutes.

**Step 1: Describe the LLMInferenceService**
```bash
oc describe llminferenceservice bielik-11b -n bielik-demo
# Look at: Status.Conditions, Events
```

**Step 2: Check llm-d controller logs**
```bash
# Find llm-d controller pod
oc get pods -A | grep -i llmd
CONTROLLER_NS=$(oc get pods -A | grep -i "llmd.*controller" | awk '{print $1}' | head -1)
CONTROLLER_POD=$(oc get pods -n "${CONTROLLER_NS}" | grep controller | awk '{print $1}' | head-1)
oc logs -f "${CONTROLLER_POD}" -n "${CONTROLLER_NS}" | grep -i "bielik\|error\|warn"
```

**Step 3: Verify CRD version**
```bash
# Ensure the CRD supports v1alpha2
oc get crd llminferenceservices.serving.kserve.io -o jsonpath='{.spec.versions[*].name}'
# Should include: v1alpha2
```

**Step 4: Check for admission webhook rejection**
```bash
# Webhook rejections appear in: oc describe llminferenceservice ... (Events section)
# Also: oc get events -n bielik-demo --field-selector reason=FailedCreate
```

---

## Verifying Pipeline Parallelism is Actually Working

**Method 1: Ray dashboard (if accessible)**
```bash
# Port-forward to Ray dashboard (port 8265)
RAY_HEAD_POD=$(oc get pods -n bielik-demo -o name | head -1 | cut -d/ -f2)
oc port-forward pod/${RAY_HEAD_POD} 8265:8265 -n bielik-demo
# Open http://localhost:8265 — should show 3 nodes in the cluster
```

**Method 2: Check vLLM startup logs**
```bash
# Each pod should show its pipeline rank
oc logs -n bielik-demo --selector=app=bielik-11b | grep -i "pipeline\|stage\|rank"
# Expected: "Pipeline stage rank: 0/1/2 of 3"
```

**Method 3: Check nvidia-smi on all nodes**
```bash
# All 3 T4 GPUs should show memory usage > 6GB after model load
for POD in $(oc get pods -n bielik-demo --no-headers | awk '{print $1}'); do
    echo "=== Pod: ${POD} ==="
    oc exec "${POD}" -n bielik-demo -- nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
done
```

**Method 4: Check Ray cluster membership from within a pod**
```bash
oc exec RAY_HEAD_POD -n bielik-demo -- python3 -c "
import ray; ray.init(address='auto')
print('Ray nodes:', len(ray.nodes()))
print('Expected: 3')
"
```

---

## Useful One-Liners

```bash
# Watch pods until Ready
oc get pods -n bielik-demo -w

# Get all logs from all pods with timestamp
oc logs -n bielik-demo -l app=bielik-11b --timestamps --tail=50

# Check GPU allocation across the cluster
oc describe nodes | grep -A6 'Allocated resources' | grep 'nvidia.com/gpu'

# Force delete a stuck pod (use with caution)
oc delete pod POD_NAME -n bielik-demo --grace-period=0 --force

# Get raw JSON status of LLMInferenceService
oc get llminferenceservice bielik-11b -n bielik-demo -o json | python3 -m json.tool
```

---

## Problem: Model transfer Job fails

**Symptoms**: `oc get job bielik-model-transfer -n bielik-demo` shows Failed, or Job never completes.

**Check 1: View Job logs**
```bash
oc logs job/bielik-model-transfer -n bielik-demo
```

**Check 2: Network egress to HuggingFace**
```bash
# Test connectivity from the transfer Job namespace
oc run hf-test --namespace=bielik-demo --rm -i --restart=Never \
  --image=python:3.11-slim \
  -- python3 -c "import urllib.request; urllib.request.urlopen('https://huggingface.co', timeout=10); print('OK')"
# If this fails: cluster has no egress to internet — contact cluster admin
```

**Check 3: MinIO connectivity from transfer Job**
```bash
# Test cross-namespace reach to MinIO
oc run minio-test --namespace=bielik-demo --rm -i --restart=Never \
  --image=quay.io/minio/mc:latest \
  -- mc alias set local http://minio.rhoai-model-registries.svc.cluster.local:9000 minio minio123
# Should print: Added `local` successfully.
```

**Check 4: MinIO is running**
```bash
oc get pods -n rhoai-model-registries -l app=minio
oc logs deployment/minio -n rhoai-model-registries
```

**Check 5: Verify model in MinIO after successful transfer**
```bash
MINIO_POD=$(oc get pod -n rhoai-model-registries -l app=minio -o name | head -1)
oc exec ${MINIO_POD} -n rhoai-model-registries -- ls /data/bielik-models/Bielik-11B-v2.3-Instruct-GPTQ/
# Should list: config.json, *.safetensors, tokenizer files, etc.
```

**Re-run transfer after fixing the issue:**
```bash
oc delete job bielik-model-transfer -n bielik-demo --ignore-not-found
./scripts/deploy.sh --skip-prereqs --skip-transfer=false
```
