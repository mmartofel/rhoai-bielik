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
```

**Cause 2: Resource quota exceeded**
```bash
# Check resource quotas in namespace
oc get resourcequota -n bielik-demo
oc describe resourcequota -n bielik-demo

# Check if enough GPU resources exist in cluster
oc describe nodes -l 'nvidia.com/gpu.present=true' | grep -A3 'Allocated resources'
```

**Cause 3: Not enough GPU nodes for 3 DP workers**
```bash
# Deployment requires 3 GPU nodes (one per DP worker)
oc get nodes -l 'nvidia.com/gpu.present=true' --no-headers | wc -l

# If fewer than 3 GPU nodes: reduce data parallelism in manifests/06-llminferenceservice.yaml
# spec.parallelism.data: 2   (and dataLocal: 1)
```

**Cause 4: CPU requests too high for loaded nodes**
```bash
# g4dn.2xlarge nodes in this cluster run at 79-94% CPU utilization
# spec.template.containers.resources.requests.cpu must be "1" (not higher)
oc get pod -n bielik-demo -o jsonpath='{.items[0].spec.containers[0].resources.requests}' 2>/dev/null
```

**Cause 5: GPU Operator not labeling nodes**
```bash
# Verify NFD and GPU Operator pods are Running
oc get pods -n nvidia-gpu-operator
oc get pods -A | grep -i nfd

# Force NFD re-detection:
oc rollout restart daemonset -n nvidia-gpu-operator node-feature-discovery-worker
```

---

## Problem: Model download fails (HuggingFace error)

**Symptoms**: Transfer Job logs show HTTP 401/403 from HuggingFace, or Job times out.

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
# Test connectivity from a pod
oc exec POD_NAME -n bielik-demo -- curl -I https://huggingface.co

# Check EgressNetworkPolicy (OpenShift-specific)
oc get egressnetworkpolicy -n bielik-demo
```

---

## Problem: OOM (Out of Memory) on T4

**Symptoms**: Pod crashes with `CUDA out of memory`, or `nvidia-smi` shows memory near 100%.

The GPTQ model uses ~5.75 GiB for weights, leaving ~10 GiB for KV cache on a 16 GiB T4. OOM typically means KV cache allocation is too large.

**Mitigation 1: Reduce max sequence length**
```bash
# In manifests/06-llminferenceservice.yaml, change the arg:
# --max-model-len=2048   (down from 4096)
```

**Mitigation 2: Reduce GPU memory utilization**
```bash
# In manifests/06-llminferenceservice.yaml:
# --gpu-memory-utilization=0.75   (down from 0.85)
```

**Mitigation 3: Monitor GPU memory**
```bash
oc exec POD_NAME -n bielik-demo -- nvidia-smi dmon -s m -d 5
```

**Mitigation 4: Verify GPTQ quantization is active**
```bash
oc logs POD_NAME -n bielik-demo | grep -i "gptq\|marlin"
# Expected: "Using MarlinLinearKernel for GPTQMarlinLinearMethod"
```

---

## Problem: LLMInferenceService stuck in NotReady

**Symptoms**: `oc get llminferenceservice` shows `Ready=False`, status doesn't change after 15+ minutes.

**Step 1: Check reason**
```bash
oc get llminferenceservice bielik-11b -n bielik-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
```

**Step 2: Describe the LLIS**
```bash
oc describe llminferenceservice bielik-11b -n bielik-demo
# Look at: Status.Conditions, Events
```

**Step 3: Check llm-d controller logs**
```bash
CONTROLLER_NS=$(oc get pods -A | grep -i "llmd.*controller" | awk '{print $1}' | head -1)
CONTROLLER_POD=$(oc get pods -n "${CONTROLLER_NS}" | grep controller | awk '{print $1}' | head -1)
oc logs -f "${CONTROLLER_POD}" -n "${CONTROLLER_NS}" | grep -i "bielik\|error\|warn"
```

**Step 4: Verify CRD version**
```bash
oc get crd llminferenceservices.serving.kserve.io -o jsonpath='{.spec.versions[*].name}'
# Should include: v1alpha2
```

**Step 5: TLS cert rotation loop**

If pods keep restarting and the LLIS shows `Stopped`, the operator may be regenerating TLS certs when pod IPs change (a known llm-d behavior). Fix: delete and recreate the LLIS.

```bash
oc delete llminferenceservice bielik-11b -n bielik-demo
oc apply -f manifests/06-llminferenceservice.yaml
```

---

## Problem: Workers not connecting to DP Coordinator

**Symptoms**: Leader logs show repeated `Waiting for READY message from DP Coordinator...` without progressing.

The DP Coordinator on the leader waits for ALL 3 workers (DP ranks 0, 1, 2) to complete their engine initialization before signaling READY.

**Check 1: Are all pods Running?**
```bash
oc get pods -n bielik-demo -o wide
# All 3 of bielik-11b-kserve-mn-0, -mn-0-1, -mn-0-2 must be Running
```

**Check 2: Are workers past the storage-initializer init container?**
```bash
oc get pods -n bielik-demo
# Workers stuck in Init:0/1 are still downloading the model from MinIO
# Model download takes ~37 seconds per pod from cluster-local MinIO
```

**Check 3: Worker logs — check for errors after init**
```bash
oc logs bielik-11b-kserve-mn-0-1 -n bielik-demo --tail=30
# Should eventually show: "init engine ... took XX seconds"
# If it shows errors instead, that's the root cause
```

**Check 4: DP Coordinator port reachability**
```bash
# Workers must reach the leader on TCP :5555
LEADER_IP=$(oc get pod bielik-11b-kserve-mn-0 -n bielik-demo -o jsonpath='{.status.podIP}')
oc exec bielik-11b-kserve-mn-0-1 -n bielik-demo -- nc -zv ${LEADER_IP} 5555
```

---

## Verifying Data Parallelism Is Working

**Check 1: All 3 pods Running on different nodes**
```bash
oc get pods -n bielik-demo -o wide
# bielik-11b-kserve-mn-0    → Node A
# bielik-11b-kserve-mn-0-1  → Node B
# bielik-11b-kserve-mn-0-2  → Node C
# All 3 should show different NODE values
```

**Check 2: Leader logs show DP Coordinator started**
```bash
oc logs bielik-11b-kserve-mn-0 -n bielik-demo | grep -i "DP Coordinator\|data parallel\|READY"
# Expected:
#   INFO ... Started DP Coordinator process (PID: 87)
#   INFO ... Launching 3 data parallel engine(s) in headless mode
#   INFO ... Application startup complete.  (from all 8 API servers)
```

**Check 3: Workers show correct DP rank**
```bash
oc logs bielik-11b-kserve-mn-0-1 -n bielik-demo | grep "DP rank"
# Expected: "DP rank 1, PP rank 0, TP rank 0"
oc logs bielik-11b-kserve-mn-0-2 -n bielik-demo | grep "DP rank"
# Expected: "DP rank 2, PP rank 0, TP rank 0"
```

**Check 4: GPU memory on all 3 nodes**
```bash
for POD in bielik-11b-kserve-mn-0 bielik-11b-kserve-mn-0-1 bielik-11b-kserve-mn-0-2; do
    echo "=== ${POD} ==="
    oc exec "${POD}" -n bielik-demo -- nvidia-smi \
        --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null || echo "Not running"
done
# Expected: ~6000 MiB used / 16160 MiB total on each node
```

**Check 5: Inference test**
```bash
ENDPOINT=$(oc get llminferenceservice bielik-11b -n bielik-demo -o jsonpath='{.status.url}')
curl -sk "${ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"bielik-11b","messages":[{"role":"user","content":"Cześć! Kim jesteś?"}],"max_tokens":50}' \
  | python3 -m json.tool
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
oc run hf-test --namespace=bielik-demo --rm -i --restart=Never \
  --image=python:3.11-slim \
  -- python3 -c "import urllib.request; urllib.request.urlopen('https://huggingface.co', timeout=10); print('OK')"
# If this fails: cluster has no egress to internet — contact cluster admin
```

**Check 3: MinIO connectivity from transfer Job**
```bash
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
./scripts/deploy.sh --skip-prereqs
```

---

## Useful One-Liners

```bash
# Watch pods until Ready
oc get pods -n bielik-demo -w

# Get all logs from all bielik pods
oc logs -n bielik-demo --selector=leaderworkerset.sigs.k8s.io/name=bielik-11b-kserve-mn \
    --timestamps --tail=50 2>/dev/null

# Check GPU allocation across the cluster
oc describe nodes | grep -A6 'Allocated resources' | grep 'nvidia.com/gpu'

# Get endpoint URL
oc get llminferenceservice bielik-11b -n bielik-demo -o jsonpath='{.status.url}'

# Force delete a stuck pod (use with caution — LWS will recreate the whole group)
oc delete pod POD_NAME -n bielik-demo --grace-period=0 --force

# Get raw JSON status of LLMInferenceService
oc get llminferenceservice bielik-11b -n bielik-demo -o json | python3 -m json.tool
```
