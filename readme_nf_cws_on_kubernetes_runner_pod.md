# nf-cws on Kubernetes — Simple Step‑by‑Step (Runner Pod approach)

This guide shows the **minimal working setup** to run **Nextflow** with the **nf-cws** plugin on **Kubernetes** using a **single runner pod** and a **PVC** for work data. The plugin will **auto‑create the CWS scheduler** in your cluster (no manual service needed).

**Namespace used below:** `yagmur`

**Files you already have:** `account.yaml`, `pvc.yaml`, `cws.yaml` (runner pod), `main.nf`, `nextflow.config`

---

## Prerequisites
- A working Kubernetes cluster and `kubectl` configured.
- Nextflow **≥ 24.04.0** available **inside the runner pod**.
- A `PersistentVolume` that can bind your `pvc.yaml` (e.g., default StorageClass).
- Your `cws.yaml` (runner) mounts the **same PVC** at **`/workspace`**.

> Tip: Ensure the ServiceAccount in `account.yaml` has the permissions used by your `cws.yaml` runner.

---

## Quick start

### 1) Apply the Kubernetes manifests
```bash
kubectl apply -n yagmur -f account.yaml
kubectl apply -n yagmur -f pvc.yaml
kubectl apply -n yagmur -f cws.yaml
```

Verify that the PVC is **Bound** and the **runner pod** is **Running**:
```bash
kubectl get pvc -n yagmur
kubectl get pods -n yagmur
```

### 2) Put your pipeline files on the shared PVC (mounted at `/workspace`)
If your image doesn’t already contain `main.nf` and `nextflow.config`, copy them in:
```bash
RUNNER_POD=$(kubectl get pod -n yagmur -o name | grep runner | sed 's|pod/||')

kubectl cp main.nf          yagmur/$RUNNER_POD:/workspace/main.nf
kubectl cp nextflow.config  yagmur/$RUNNER_POD:/workspace/nextflow.config
```
> Adjust the pod selector if your runner pod name doesn’t include `runner`.

### 3) Run Nextflow **inside the runner pod**
Open a shell:
```bash
kubectl exec -it -n yagmur $RUNNER_POD -- bash
```
Set a writable Nextflow home on the PVC (helps cache the plugin) and launch:
```bash
export NXF_HOME=/workspace/.nextflow
export NXF_WORK=/workspace/work   # optional if set in nextflow.config

nextflow run /workspace/main.nf \
  -c /workspace/nextflow.config \
  -with-report /workspace/report.html \
  -with-timeline /workspace/timeline.html \
  -with-trace
```
The **nf-cws** plugin will start and **auto‑provision** the scheduler components in your cluster. Nextflow task pods will then be created to execute your workflow.

### 4) Watch the workflow
In another terminal:
```bash
kubectl get pods -n yagmur -w
```
You should see the runner pod plus task pods created by Nextflow.

### 5) Retrieve outputs & reports
Artifacts, work, and reports are written under `/workspace` on the PVC:
- Work directory: `/workspace/work`
- Reports: `/workspace/report.html`, `/workspace/timeline.html`
- (Your pipeline may write results to another path under `/workspace`)

---

## Minimal `nextflow.config`
If you already have one, compare it to this minimal example and adapt names to match your manifests.

```groovy
// Enable the CWS plugin
plugins {
  id 'nf-cws'
}

// Use the Kubernetes executor
process {
  executor = 'k8s'
}

k8s {
  namespace = 'yagmur'                 // your namespace
  serviceAccount = 'nextflow'           // from account.yaml (example)
  storageClaimName = 'work-pvc'         // from pvc.yaml metadata.name
  launchDir = '/workspace'              // PVC mount point in runner
}

workDir = '/workspace/work'             // keep work on the PVC

// Optional niceties
docker.enabled = true                   // if tasks use containers
cleanup = true
```

> **Note:** Many pipelines also define container images per process. Ensure images are accessible to your cluster.

---

## Troubleshooting
- **PVC stays `Pending`** → Check StorageClass and PV availability: `kubectl get sc,pv -A`.
- **Runner can’t write plugin cache** → Ensure `NXF_HOME` points to a writable path (e.g., `/workspace/.nextflow`).
- **RBAC/permission issues** → Confirm `ServiceAccount`, `Role/ClusterRole`, and bindings in `account.yaml` match what your runner and tasks need.
- **No task pods appear** → Check runner logs: `kubectl logs -n yagmur $RUNNER_POD -f`. Ensure `executor = 'k8s'` and plugin `nf-cws` is enabled.
- **Images can’t pull** → Configure imagePullSecrets or use public images.

---

## Clean up
Keep the PVC if you want to preserve results; otherwise delete it too.
```bash
kubectl delete -n yagmur -f cws.yaml
kubectl delete -n yagmur -f account.yaml
# Preserve data by keeping the PVC; delete only if you’re sure
kubectl delete -n yagmur -f pvc.yaml   # WARNING: deletes your data
```

---

## What you get
- A **single runner pod** that launches Nextflow.
- **Persistent work and reports** on a shared PVC.
- The **CWS scheduler auto‑created** by the plugin—no manual service required.

That’s it—minimal, reproducible, and easy to adapt for your cluster.

