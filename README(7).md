# Nextflow + nf-cws on Kubernetes
**Mode:** external **scheduler pod** + **runner pod** (CWS exposed via Service)

This repository is a **minimal, reproducible walkthrough** for running **Nextflow** with the **nf-cws** plugin on **Kubernetes** using **two pods**:
- A **CWS scheduler** pod exposed by a ClusterIP **Service**
- A **Nextflow runner** pod that launches workflows and connects to the scheduler

```
Nextflow (runner pod)  --->  cws-scheduler Service  --->  workflow-scheduler Pod
           \--> task pods (scheduled by CWS) in namespace: yagmur
```

> This README focuses on **how to run** the setup step-by-step.  
> All manifests and pipeline files are already in the repo—**no need to paste their full contents here**.

---

## Repository layout
```
account.yaml       # ServiceAccount + Role/RoleBinding (cwsaccount)
pvc.yaml           # PersistentVolumeClaim (e.g., nextflow-pvc)
cws.yaml           # CWS scheduler Pod (name: workflow-scheduler)
cws-service.yaml   # Service exposing the scheduler as cws-scheduler:8080
nf-runner.yaml     # Nextflow runner Pod (name: nf-runner) with PVC at /workspace
main.nf            # Your pipeline script
nextflow.config    # Nextflow config (uses cws { dns = ... } to reach the Service)
```

---

## Prerequisites
- Kubernetes cluster + `kubectl` configured
- Namespace: **`yagmur`**
- `ServiceAccount`/RBAC for **`cwsaccount`** (in `account.yaml`)
- A `PersistentVolumeClaim` named **`nextflow-pvc`** (in `pvc.yaml`)
- **Nextflow ≥ 24.04.0** available in the runner image (as used by `nf-runner.yaml`)
- If your `cws.yaml` mounts additional PVCs (e.g., `api-exp-input`, `api-exp-data`), ensure they exist or adapt that file

> **Important:** In this mode you **do not** define `k8s.scheduler { ... }` in `nextflow.config`.  
> The config uses an **existing scheduler** via `cws { dns = "http://cws-scheduler:8080" }`.

---

## Quick start (5–10 minutes)

### 0) Get the repo ready
Pick a clean directory for testing and **download/clone this repository** there:
```bash
# Example (replace with your repo URL if needed)
git clone <YOUR_REPO_URL> nf-cws-k8s-scheduler-runner
cd nf-cws-k8s-scheduler-runner
```

### 1) Apply manifests
```bash
# RBAC + PVC (apply once if not already present)
kubectl -n yagmur apply -f account.yaml
kubectl -n yagmur apply -f pvc.yaml

# Scheduler pod + Service
kubectl -n yagmur apply -f cws.yaml
kubectl -n yagmur apply -f cws-service.yaml

# Runner pod
kubectl -n yagmur apply -f nf-runner.yaml

# Wait until both pods are Running
kubectl -n yagmur get pods,svc
```

### 2) Copy the pipeline files into the runner
From the **repo folder**, copy these two files into the runner’s mounted workspace:
```bash
kubectl -n yagmur cp nextflow.config nf-runner:/workspace/nextflow.config
kubectl -n yagmur cp main.nf         nf-runner:/workspace/main.nf
```

### 3) Launch the workflow
Run Nextflow **inside** the runner pod:
```bash
kubectl -n yagmur exec -it nf-runner -- sh -lc \
  'cd /workspace && nextflow run main.nf -plugins nf-cws -name ws-$(date +%s)'
```
What should happen:
- Nextflow connects to **http://cws-scheduler:8080**
- CWS schedules **task pods** in the `yagmur` namespace
- Work files appear under **`/workspace/work`** on the PVC

### 4) Verify
```bash
kubectl -n yagmur get pods,svc
kubectl -n yagmur logs pod/workflow-scheduler
kubectl -n yagmur describe pod <a-task-pod>
kubectl -n yagmur exec -it nf-runner -- sh -lc 'ls -la /workspace && ls -la /workspace/work'
```

---

## Troubleshooting

**Nextflow can’t reach CWS**
```bash
kubectl -n yagmur get svc cws-scheduler
kubectl -n yagmur get endpoints cws-scheduler
kubectl -n yagmur exec -it nf-runner -- sh -lc \
  "command -v curl >/dev/null || (apk add --no-cache curl || apt-get update && apt-get install -y curl || true); \
   curl -sf http://cws-scheduler:8080/health || curl -sS http://cws-scheduler:8080"
```

**RBAC forbidden**
- Ensure `cwsaccount` Role/RoleBinding allows: `pods`, `pods/log`, `services`, `configmaps`, `events` within `yagmur`

**Tasks Pending**
- Not enough resources → lower `cpus`/`memory` in `process` blocks or scale nodes
- Taints/selectors → check `kubectl describe pod` events

**PVC not mounted**
- `nextflow-pvc` must be **Bound**
- Runner must mount it at **`/workspace`**
- `nextflow.config` must reference the same claim/path via `storageClaimName` and `storageMountPath`

---

## Clean up
```bash
kubectl -n yagmur delete -f nf-runner.yaml --ignore-not-found
kubectl -n yagmur delete -f cws-service.yaml --ignore-not-found
kubectl -n yagmur delete -f cws.yaml --ignore-not-found
# If you also created RBAC/PVC here:
kubectl -n yagmur delete -f pvc.yaml -f account.yaml --ignore-not-found
```

---

## Notes & scope
- This repo contains a **simple step-by-step tutorial** that implements what is described in the upstream projects below.  
- It is intentionally minimal so you can **run it as-is** and then adapt to your own pipelines and cluster policies.

---

## Credits & references
This setup follows the work in these repositories by **Fabian Lehmann**:

- CommonWorkflowScheduler Kubernetes Scheduler  
  https://github.com/CommonWorkflowScheduler/KubernetesScheduler

- nf-cws (Nextflow plugin for CWS)  
  https://github.com/CommonWorkflowScheduler/nf-cws

> All credit for nf-cws and the Kubernetes scheduler implementation goes to Fabian Lehmann and contributors.  
> This repository merely provides a compact, worked example of how to run those components together on Kubernetes.
