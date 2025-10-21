# Nextflow + nf-cws on Kubernetes (scheduler pod + runner pod)

This guide shows how to run **Nextflow** with the **nf-cws** plugin by:

- Deploying a **CWS scheduler pod** (`cws.yaml`)
- Exposing it via a **Service** (`cws-service.yaml`)
- Running Nextflow inside a **runner pod** (`nf-runner.yaml`)

```
Nextflow (runner) ---> cws-scheduler Service ---> workflow-scheduler Pod
        \--> task pods (scheduled by CWS)

Namespace: `yagmur`
```

---

## Prerequisites

- Namespace `yagmur`
- `ServiceAccount`/RBAC for `cwsaccount` (`account.yaml`)
- `PersistentVolumeClaim` named `nextflow-pvc` (`pvc.yaml`)
- A working Kubernetes cluster with `kubectl` configured
- **Nextflow ≥ 24.04.0** (the `nf-runner.yaml` image is fine)
- Your `cws.yaml` mounts `api-exp-input` and `api-exp-data`. Ensure those PVCs exist or adjust that file.

---

## 1) Apply the manifests
```bash
# RBAC + PVC (if not already applied)
kubectl -n yagmur apply -f account.yaml
kubectl -n yagmur apply -f pvc.yaml

# Scheduler pod
kubectl -n yagmur apply -f cws.yaml

# Service exposing the scheduler
kubectl -n yagmur apply -f cws-service.yaml

# Runner pod with Nextflow
kubectl -n yagmur apply -f nf-runner.yaml

# Wait until both pods are Running
kubectl -n yagmur get pods,svc
```

Example `cws-service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: cws-scheduler
  namespace: yagmur
spec:
  selector:
    app: cws
    component: scheduler
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

---

## 2) Put `nextflow.config` into the runner

This config **uses the existing scheduler** via `cws { dns = ... }`.
Do **not** add a `k8s.scheduler { ... }` block in this mode.

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
}

cws {
  // Reach the scheduler via the Service you created
  dns = 'http://cws-scheduler:8080'
  // Optional tuning:
  // strategy     = 'rank_max-fair'
  // costFunction = 'MinSize'
  // batchSize    = 10
  // minMemory    = 128.MB
  // maxMemory    = 64.GB
}
EOF
```

(Optional) inspect it:
```bash
kubectl -n yagmur exec -it nf-runner -- sh -lc 'sed -n "1,200p" /workspace/nextflow.config'
```

---

## 3) Put `main.nf` into the runner (example)

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

---

## 4) Run Nextflow from the runner
```bash
kubectl -n yagmur exec -it nf-runner -- sh -lc   'cd /workspace && nextflow run main.nf -plugins nf-cws -name ws-$(date +%s)'
```

### What you should see
- Nextflow connects to `http://cws-scheduler:8080`
- CWS creates/schedules task pods in `yagmur`
- Work files appear under `/workspace/work` (backed by `nextflow-pvc`)

---

## 5) Verify

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
kubectl -n yagmur exec -it nf-runner -- sh -lc   "apk add --no-cache curl || true; curl -sf http://cws-scheduler:8080/health || curl -sS http://cws-scheduler:8080"
```

**RBAC forbidden**
- Ensure `cwsaccount` Role/RoleBinding allows `pods`, `pods/log`, `services`, `configmaps`, `events`.

**Tasks Pending**
- Resource pressure → lower `cpus`/`memory` in processes or scale nodes.
- Taints/selectors → check `kubectl describe pod` events.

**PVC not mounted**
- `nextflow-pvc` must be `Bound`.
- Runner must mount it at `/workspace`.
- Ensure `storageClaimName` + `storageMountPath` in `nextflow.config` match.

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

## Why separate pods?

- **Separation of concerns & lifecycle**: Scheduler is control-plane; runner is user workload. You can restart/replace one without touching the other.
- **Images & tooling**: Scheduler image doesn’t have Nextflow; runner image does.
- **RBAC & mounts**: Runner mounts your workspace PVC; scheduler doesn’t need it. Mixing complicates security and storage.

If you later prefer fewer moving parts, you can:
- Run Nextflow on your laptop and port-forward to the Service, or
- Remove `cws.yaml`/`cws-service.yaml` and let nf-cws auto-start the scheduler by adding `k8s.scheduler { ... }` and omitting the `cws { dns=... }` block.
