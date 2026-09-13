# python-devops-drill

A Python-for-DevOps interview practice site — 34 self-graded exercises with a real
in-browser Python editor (via Skulpt), bash-analogy talk-tracks, and a memory-hook
per question. Also, deliberately, a live example of shipping a static site through
a real GitOps pipeline instead of just serving the HTML file directly.

**Live app:** served from `index.html` — a single self-contained page (HTML/CSS/JS
inline, only Google Fonts and Skulpt loaded from a CDN).

## How this is deployed

```
index.html  →  Docker image  →  Docker Hub  →  Helm chart  →  ArgoCD  →  Kubernetes
```

- **Dockerfile** — `nginx:alpine` serving `index.html`.
- **.github/workflows/docker-publish.yml** — on every push to `main` that touches
  `index.html` or the `Dockerfile`, GitHub Actions builds the image and pushes it to
  Docker Hub as `prnvdas/python-devops-drill:latest` and `:<git-sha>`.
- **helm/python-devops-drill/** — the Helm chart (Deployment + Service), parameterized
  via `values.yaml` (image repo/tag, replica count, resource limits, probes).
- **argocd/application.yaml** — an ArgoCD `Application` pointing at this repo's Helm
  chart with `automated: {prune: true, selfHeal: true}` — ArgoCD continuously
  reconciles the live cluster to match what's committed here. No `kubectl apply`,
  no manual deploys: push to `main`, ArgoCD picks up the new chart/values within its
  sync interval (default 3 min, or immediately via a manual sync).

## Cluster setup (kind + Calico)

The cluster this currently runs on is a local `kind` cluster, defined in
`kind-cluster.yaml`: 1 control-plane + 2 workers, default CNI disabled in favor
of **Calico** (kind's default CNI doesn't enforce `NetworkPolicy` at all — Calico
does), and ports 80/443 published on the control-plane node at cluster-creation
time so `http://localhost/` works with zero `kubectl port-forward`.

To recreate it from scratch:
```bash
kind create cluster --config kind-cluster.yaml

# Calico (NetworkPolicy enforcement)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# ingress-nginx (kind's dedicated manifest)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# REQUIRED FIX: the upstream manifest above only *tolerates* the control-plane
# taint, it doesn't *require* landing there — with untainted worker nodes also
# available, the scheduler may place the ingress pod on a worker instead. Since
# ingress-nginx binds via hostPort (not a Service), it only works on the exact
# node whose Docker container has 80/443 published — which is only the
# control-plane node here. Force it explicitly:
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/nodeSelector/ingress-ready","value":"true"}]'
```

## Accessing the app

The Ingress routes by hostname (`pythonfordevops.local`), not `localhost`, so it can
sit on the same ingress-nginx controller as ArgoCD's own `argocd.local` without the
two colliding. Add this line to your **Windows** hosts file
(`C:\Windows\System32\drivers\etc\hosts`, edited as Administrator):
```
127.0.0.1 pythonfordevops.local
```
Then open `http://pythonfordevops.local/`.

## One-time setup (things only you can do)

1. **Docker Hub secrets** — in this repo's GitHub Settings → Secrets and variables →
   Actions, add:
   - `DOCKERHUB_USERNAME`
   - `DOCKERHUB_TOKEN` (an access token, not your password — Docker Hub →
     Account Settings → Security → New Access Token)
2. **Install ArgoCD**, then **apply the ArgoCD Application**:
   ```
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts
   kubectl apply -f argocd/application.yaml
   ```
   (`--server-side` avoids a known `kubectl apply` failure where ArgoCD's
   `applicationsets.argoproj.io` CRD exceeds the `kubectl.kubernetes.io/last-applied-configuration`
   annotation size limit.)

## Local development (no ArgoCD/registry involved)

```
docker build -t python-devops-drill:local .
docker run -p 8080:80 python-devops-drill:local
# open http://localhost:8080
```

## Roadmap — "full-blown DevOps project"

Not built yet, listed here so the direction is explicit rather than implied:

- **CI quality gates**: lint the Helm chart (`helm lint`) and run the existing
  JS smoke-test suite in CI before allowing a merge to `main`.
- **Image security scanning**: Trivy (or Grype) scan step in the workflow, failing
  the build on high/critical CVEs in the base image.
- **Multiple environments**: split `values.yaml` into `values-dev.yaml` /
  `values-prod.yaml`, and either two ArgoCD Applications or an ArgoCD ApplicationSet.
- **Image tag automation**: ArgoCD Image Updater (or Argo CD + a bump-version PR
  step) instead of `:latest`, so deployments are pinned to an exact, auditable SHA.
- **Observability**: Prometheus + Grafana (or just nginx access log shipping) so
  the "production" instance has real metrics, not just a readiness probe.
- **TLS**: ingress-nginx is in place, but it's plain HTTP — cert-manager +
  a real (or self-signed) cert if this ever leaves localhost.
- **Infra as code**: if this moves to a real cloud cluster, Terraform for the
  cluster itself, so "click ArgoCD install script" isn't a manual step either.
- **Branch protection + PR review**: require the CI workflow to pass before merge.
