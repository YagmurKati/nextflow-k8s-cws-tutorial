# nf-cws on Kubernetes - Runner Pod approach

This guide shows the **minimal working setup** to run **Nextflow** with the **nf-cws** plugin on **Kubernetes** using a **single runner pod** and a **PVC** for work data. The plugin will **auto-create the CWS scheduler** in your cluster (**no manual service** needed).

**Namespace used below:** `yagmur`  
**Files you already have:** `account.yaml`, `pvc.yaml`, `cws.yaml` (runner pod), `main.nf`, `nextflow.config`

---

## Prerequisites
- A working Kubernetes cluster and `kubectl` configured.
- **Nextflow ≥ 24.04.0** available **inside the runner pod**.
- A `PersistentVolume` that can bind your `pvc.yaml` (e.g., default StorageClass).
- Your `cws.yaml` (runner) **mounts the same PVC at** `/workspace`.

---

## 1) Apply the Kubernetes manifests
```bash
# Create RBAC / ServiceAccounts
kubectl -n yagmur apply -f account.yaml

# Create the persistent volume claim used by Nextflow work dir
kubectl -n yagmur apply -f pvc.yaml

# Create the Nextflow runner pod (must mount the PVC at /workspace)
kubectl -n yagmur apply -f cws.yaml
```

Wait until the runner pod is **Ready**:
```bash
kubectl -n yagmur get pods
# look for: nf-runner   1/1   Running
```

## 2) Open a shell in the runner pod
```bash
kubectl -n yagmur exec -it nf-runner -- bash
# If the image doesn't have bash:
# kubectl -n yagmur exec -it nf-runner -- sh
```
Verify Nextflow version (must be **≥ 24.04.0**):
```bash
nextflow -version
```

## 3) Create `nextflow.config` inside the pod
This config uses the **k8s** executor, mounts the PVC at `/workspace`, sets `workDir` to `/workspace/work`, and lets **nf-cws** create the scheduler (**no `cws { dns=... }`**).

```bash
kubectl -n yagmur exec -i nf-runner -- sh -lc 'cat > /workspace/nextflow.config' <<'EOF'
plugins { id 'nf-cws' }

process {
  executor = 'k8s'
  container = 'ubuntu:24.04'
  shell = ['/bin/bash','-ueo','pipefail']
}

k8s {
  namespace = 'yagmur'
  serviceAccount = 'cwsaccount'
  storageClaimName = 'nextflow-pvc'
  storageMountPath = '/workspace'
  workDir = '/workspace/work'

  // Let nf-cws create the scheduler (no cws { dns = ... }).
  // Reuse the same SA; ensure it has RBAC for pods/services/configmaps/events.
  scheduler {
    name            = 'workflow-scheduler'
    serviceAccount  = 'cwsaccount'
    container       = 'commonworkflowscheduler/kubernetesscheduler:latest'
    cpu             = '2'
    memory          = '1400Mi'
    port            = 8080
    runAsUser       = 0
    imagePullPolicy = 'IfNotPresent'
    // Robust start: try /app/cws.jar, else /cws.jar
    command         = ['/bin/sh','-lc','test -f /app/cws.jar && exec java -jar /app/cws.jar || exec java -jar /cws.jar']
    // Optional: autoClose = true
  }
}
EOF
```
(Optional) Inspect it:
```bash
kubectl -n yagmur exec -it nf-runner -- sh -lc 'sed -n "1,200p" /workspace/nextflow.config'
```

## 4) Create a minimal `main.nf` (if you don’t already have one)
```bash
kubectl -n yagmur exec -i nf-runner -- sh -lc 'cat > /workspace/main.nf' <<'EOF'
nextflow.enable.dsl=2

process SAY_HELLO {
  cpus 1
  memory '512 MB'
  input:
    val name
  output:
    stdout
  """
  echo "hello $name from $HOSTNAME"
  """
}

workflow {
  Channel.of('Ada','Grace','Linus') | SAY_HELLO | view()
}
EOF
```

## 5) Run the pipeline (from outside the pod)
```bash
kubectl -n yagmur exec -it nf-runner -- sh -lc \
  'cd /workspace && nextflow run main.nf -plugins nf-cws -name ws-$(date +%s)'
```

### What will happen
- The **nf-cws** plugin **deploys the CWS scheduler** in namespace `yagmur` using the `scheduler { ... }` block.
- Task pods are scheduled by CWS and will mount your PVC at `/workspace`.
- Nextflow writes work files under `/workspace/work`.

## 6) Watch what’s happening
```bash
# All pods/services in the namespace
kubectl -n yagmur get pods,svc

# Scheduler logs (name from scheduler.name)
kubectl -n yagmur logs deploy/workflow-scheduler

# Inspect a task pod if needed
kubectl -n yagmur describe pod <task-pod-name>
```

**Outputs and work directory:**
```bash
kubectl -n yagmur exec -it nf-runner -- sh -lc 'ls -la /workspace && ls -la /workspace/work'
```

---

## Notes & Tips
- **PVC wiring:** `storageClaimName` + `storageMountPath` make Nextflow mount the same PVC into each task pod, so all state persists in `/workspace`.
- **Scheduler lifecycle:** If you want the scheduler to be torn down automatically at the end of the run, set `autoClose = true` inside `k8s.scheduler { ... }`.
- **RBAC:** The `cwsaccount` must be allowed (via Role/RoleBinding) to manage **pods, services, configmaps, and events** within the `yagmur` namespace. Using one SA for both tasks and scheduler is fine if RBAC permits it.
- **Shell:** Ensure your task image has `/bin/bash` (Ubuntu 24.04 does). Otherwise, change `shell` accordingly.
- **Do not** set `cws { dns = ... }` when you want the plugin to **auto-start** the scheduler. That block tells Nextflow to use an **existing** scheduler instead.

---

## Troubleshooting
**Connection to CWS fails / scheduler missing**
- Ensure you did **not** define a `cws { dns = ... }` block.
- Check resources: `kubectl -n yagmur get deploy,svc | grep workflow-scheduler`.
- Logs: `kubectl -n yagmur logs deploy/workflow-scheduler`.

**RBAC “forbidden” errors**
- Verify `cwsaccount` Role/RoleBinding in `account.yaml` includes verbs for `pods`, `pods/log`, `services`, `configmaps`, `events`.

**PVC not mounted**
- Confirm `pvc.yaml` is **Bound** and your runner `cws.yaml` mounts it at `/workspace`.
- Ensure `storageClaimName` & `storageMountPath` match the PVC and path in the runner pod.

**Tasks stuck Pending**
- Not enough cluster resources; lower `cpus`/`memory` in your processes or scale nodes.
- Node selectors/taints might prevent scheduling.

---

## Clean up
```bash
# If you enabled autoClose=false and want to remove the scheduler:
kubectl -n yagmur delete deploy/workflow-scheduler svc/workflow-scheduler --ignore-not-found

# Remove runner + PVC + RBAC (careful: PVC deletion may delete data)
kubectl -n yagmur delete -f cws.yaml -f pvc.yaml -f account.yaml
```

---

## File Map (for reference)
```
.
├─ account.yaml     # SA + RBAC for `cwsaccount`
├─ pvc.yaml         # PersistentVolumeClaim (e.g., nextflow-pvc)
├─ cws.yaml         # nf-runner pod/deployment mounting PVC at /workspace
├─ main.nf          # Your Nextflow pipeline
└─ nextflow.config  # Config shown above (auto-start scheduler)
```

