# devops-task-gitops

GitOps repository for [devops-task-api](https://github.com/ahsenbulut/devops-task-api).
This repository is the single source of truth for what runs in Kubernetes; Argo CD
continuously reconciles the cluster against the `main` branch.

## Layout

```text
apps/
└── task-api/
    ├── base/              # Deployment, Service, ServiceAccount, ConfigMap
    └── overlays/
        └── dev/           # Namespace (Pod Security "restricted"), env label, image digest
argocd/
└── task-api-dev.yaml      # Argo CD Application for the dev environment
```

## Environments

| Application           | Path                         | Cluster                          | Namespace     |
| --------------------- | ---------------------------- | -------------------------------- | ------------- |
| `devops-task-api-dev` | `apps/task-api/overlays/dev` | `https://kubernetes.default.svc` | `devops-case` |

Sync policy: automated, self-heal enabled, prune disabled, empty syncs not allowed.

## Deploying a new image

Images are referenced by immutable digest only. A release is promoted by changing the
digest in `apps/task-api/overlays/dev/kustomization.yaml` and merging to `main`:

```bash
cd apps/task-api/overlays/dev
kustomize edit set image docker.io/ahsen16/devops-task-api@sha256:<digest>
```

Use the digest printed by the application repository's Release workflow (it is only
published after passing the Trivy scan). Argo CD picks up the change automatically.

## Bootstrap

Argo CD v3.5.5 (tested with Kubernetes v1.33-v1.36), installed with the official manifest
pinned to the release commit:

```bash
kubectl --context docker-desktop create namespace argocd
kubectl --context docker-desktop apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/a5038b0e2bbac1715754380ae0084df8e3d5b48c/manifests/install.yaml
```

`install.yaml` at that commit has SHA-256
`90dc9094bf4c5964afd9c0e35d735e1c2fcbbda4f8e36799c092d9864ed65f50`.

Register the application:

```bash
kubectl --context docker-desktop apply -f argocd/task-api-dev.yaml
```

The Application has no `resources-finalizer`: deleting it stops management but leaves the
running workload in place.

UI access:

```bash
kubectl --context docker-desktop -n argocd port-forward svc/argocd-server 8080:443
kubectl --context docker-desktop -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Local validation

```bash
kubectl kustomize apps/task-api/overlays/dev
kubectl --context docker-desktop apply --dry-run=server -k apps/task-api/overlays/dev
```
