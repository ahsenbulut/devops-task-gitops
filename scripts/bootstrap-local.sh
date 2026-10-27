#!/usr/bin/env bash
# Rebuilds the local devops-case environment from this GitOps repository.
#   ./scripts/bootstrap-local.sh [--context k3s-local|docker-desktop] [--prepare]
#   --context  cluster to use (default k3s-local); the current kubectl context is never changed
#   --prepare  Argo CD, namespaces and Secrets only (before pushing GitOps changes)
set -Eeuo pipefail

CONTEXT=k3s-local
ARGOCD_VERSION=v3.5.5
ARGOCD_COMMIT=a5038b0e2bbac1715754380ae0084df8e3d5b48c
ARGOCD_SHA256=90dc9094bf4c5964afd9c0e35d735e1c2fcbbda4f8e36799c092d9864ed65f50
APP_NAMESPACE=devops-case
APP_DEPLOYMENT=devops-task-api
UI_DEPLOYMENT=devops-task-ui
DB_STATEFULSET=postgres
DB_PVC=data-postgres-0
DB_SECRET=postgres-credentials
DB_USER=taskapi
DB_NAME=tasks
KEYCHAIN_SERVICE=devops-case-postgres
MONITORING_NAMESPACE=monitoring
GRAFANA_SECRET=grafana-admin
GRAFANA_KEYCHAIN_SERVICE=devops-case-grafana
TIMEOUT=300s

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${ROOT}/apps/task-api/overlays/dev"
MIGRATIONS="${ROOT}/apps/task-api/migrations"
MODE=full
usage() { echo "usage: $0 [--context k3s-local|docker-desktop] [--prepare]" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare) MODE=prepare ;;
    --context) [[ $# -ge 2 ]] || usage; CONTEXT="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

case "${CONTEXT}" in
  k3s-local)
    NODE_NAME=devops-k3s
    SERVER_PATTERN='^https://(10\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|192\.168\.[0-9.]+):6443$'
    START_HINT="Start the VM with 'multipass start devops-k3s' and wait until the node is Ready."
    ;;
  docker-desktop)
    NODE_NAME=desktop-control-plane
    SERVER_PATTERN='^https://(127\.0\.0\.1|localhost|kubernetes\.docker\.internal):[0-9]+$'
    START_HINT="Start Docker Desktop and enable Kubernetes (Settings > Kubernetes)."
    ;;
  *) echo "ERROR: unsupported context '${CONTEXT}'; use k3s-local or docker-desktop" >&2; exit 2 ;;
esac

CURRENT_STEP="start"
PF_PID=""

k() { kubectl --context "${CONTEXT}" "$@"; }
step() { CURRENT_STEP="$*"; printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${PF_PID}" ]]; then kill "${PF_PID}" 2>/dev/null || true; fi
}

diagnose() {
  trap - ERR
  set +e
  printf '\n---- diagnostics (failed step: %s) ----\n' "${CURRENT_STEP}" >&2
  for ns in argocd "${APP_NAMESPACE}"; do
    k get namespace "${ns}" >/dev/null 2>&1 || continue
    printf '\n[%s] pods\n' "${ns}" >&2
    k -n "${ns}" get pods -o wide >&2
    k -n "${ns}" get pods --no-headers 2>/dev/null | awk '{split($2, r, "/"); if (r[1] != r[2] || $3 != "Running") print $1}' |
      while read -r pod; do
        printf '\n[%s] %s: recent events\n' "${ns}" "${pod}" >&2
        k -n "${ns}" get events --field-selector "involvedObject.name=${pod}" --sort-by=.lastTimestamp 2>/dev/null | tail -5 >&2
        printf '[%s] %s: last log lines\n' "${ns}" "${pod}" >&2
        k -n "${ns}" logs "${pod}" --all-containers --tail=10 2>&1 | tail -10 >&2
      done
  done
  if k get crd applications.argoproj.io >/dev/null 2>&1; then
    printf '\n[argocd] applications\n' >&2
    k -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,MESSAGE:.status.conditions[*].message' >&2
  fi
}

on_error() {
  local rc=$?
  diagnose
  printf '\nERROR: bootstrap failed during "%s" (exit %s). Nothing was deleted; fix the cause and re-run the script.\n' "${CURRENT_STEP}" "${rc}" >&2
  exit "${rc}"
}
trap on_error ERR
trap cleanup EXIT

check_prerequisites() {
  step "Checking local tools"
  local tool
  for tool in kubectl git curl shasum openssl security; do
    command -v "${tool}" >/dev/null || die "'${tool}' is not installed or not on PATH"
  done
  ok "kubectl, git, curl, shasum, openssl, security"
}

check_cluster() {
  step "Checking the ${CONTEXT} cluster"
  kubectl config get-contexts -o name | grep -qx "${CONTEXT}" ||
    die "kube context '${CONTEXT}' not found. ${START_HINT}"
  local cluster server
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${CONTEXT}\")].context.cluster}")"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}")"
  [[ "${server}" =~ ${SERVER_PATTERN} ]] ||
    die "context '${CONTEXT}' points to '${server}', which is not the expected local cluster address. Refusing to continue."
  k get --raw /readyz --request-timeout=5s >/dev/null 2>&1 ||
    die "Kubernetes API at ${server} is not reachable. ${START_HINT}"
  [[ "$(k get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]] ||
    die "node '${NODE_NAME}' not found or not Ready on context '${CONTEXT}'."
  ok "${CONTEXT} -> ${server}, node ${NODE_NAME} ready"

  local arch storage_class
  arch="$(k get node "${NODE_NAME}" -o jsonpath='{.status.nodeInfo.architecture}')"
  [[ "${arch}" == "arm64" || "${arch}" == "amd64" ]] ||
    die "node architecture '${arch}' is not supported; images are published for linux/amd64 and linux/arm64."
  storage_class="$(k get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}')"
  [[ -n "${storage_class}" ]] ||
    die "no default StorageClass; the PostgreSQL PVC needs one."
  ok "architecture ${arch}, default StorageClass ${storage_class% }"
}

check_gitops_repo() {
  step "Checking that the local GitOps repository matches origin/main"
  git -C "${ROOT}" fetch --quiet origin main
  [[ -z "$(git -C "${ROOT}" status --porcelain)" ]] ||
    die "the GitOps repository has uncommitted changes. Commit and push them first (Argo CD deploys origin/main)."
  [[ "$(git -C "${ROOT}" rev-parse HEAD)" == "$(git -C "${ROOT}" rev-parse origin/main)" ]] ||
    die "local HEAD differs from origin/main. Run 'git pull --ff-only' or push your commits first."
  ok "$(git -C "${ROOT}" log --oneline -1 origin/main)"
}

install_argocd() {
  step "Argo CD ${ARGOCD_VERSION}"
  if k -n argocd get deployment argocd-server >/dev/null 2>&1; then
    local image
    image="$(k -n argocd get deployment argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}')"
    [[ "${image}" == *":${ARGOCD_VERSION}" ]] ||
      die "Argo CD is installed with '${image}', expected ${ARGOCD_VERSION}. Upgrade it deliberately; the script will not change it."
    ok "already installed (${image})"
  else
    k get namespace argocd >/dev/null 2>&1 || k create namespace argocd >/dev/null
    local manifest
    manifest="$(mktemp)"
    curl -fsSL --proto '=https' --retry 3 -o "${manifest}" \
      "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_COMMIT}/manifests/install.yaml"
    echo "${ARGOCD_SHA256}  ${manifest}" | shasum -a 256 -c --status ||
      die "Argo CD install manifest checksum mismatch; refusing to apply it."
    k apply -n argocd --server-side --force-conflicts -f "${manifest}" >/dev/null
    rm -f "${manifest}"
    ok "installed from commit ${ARGOCD_COMMIT} (sha256 verified)"
  fi
  local workload
  for workload in $(k -n argocd get deployment,statefulset -o name); do
    k -n argocd rollout status "${workload}" --timeout="${TIMEOUT}" >/dev/null
  done
  ok "all Argo CD components are ready"
}

ensure_app_namespace() {
  step "Namespace ${APP_NAMESPACE}"
  if k get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
    ok "exists"
    return
  fi
  # The Namespace is the only rendered object carrying this label; Argo CD adopts it unchanged later.
  kubectl kustomize "${OVERLAY}" |
    k apply -l pod-security.kubernetes.io/enforce=restricted -f - >/dev/null
  ok "created from ${OVERLAY#"${ROOT}"/}"
}

ensure_db_secret() {
  step "PostgreSQL Secret ${DB_SECRET}"
  if k -n "${APP_NAMESPACE}" get secret "${DB_SECRET}" >/dev/null 2>&1; then
    ok "exists, left unchanged"
    return
  fi
  local password
  password="$(security find-generic-password -s "${KEYCHAIN_SERVICE}" -a "${DB_USER}" -w 2>/dev/null || true)"
  if [[ -n "${password}" ]]; then
    ok "password read from macOS Keychain (${KEYCHAIN_SERVICE})"
  else
    if k -n "${APP_NAMESPACE}" get pvc "${DB_PVC}" >/dev/null 2>&1; then
      die "PVC ${DB_PVC} already holds a database but the Keychain has no password for it. Restore the Keychain item instead of generating a new password."
    fi
    password="$(openssl rand -hex 24)"
    security add-generic-password -s "${KEYCHAIN_SERVICE}" -a "${DB_USER}" -w "${password}"
    ok "new password generated and stored in macOS Keychain (${KEYCHAIN_SERVICE})"
  fi
  k -n "${APP_NAMESPACE}" create secret generic "${DB_SECRET}" \
    --from-env-file=<(printf 'POSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=%s\n' "${DB_USER}" "${password}" "${DB_NAME}") >/dev/null
  unset password
  k -n "${APP_NAMESPACE}" label secret "${DB_SECRET}" app.kubernetes.io/managed-by=bootstrap-local >/dev/null
  ok "created (value not printed)"
}

ensure_monitoring_namespace() {
  step "Namespace ${MONITORING_NAMESPACE}"
  if k get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    ok "exists"
    return
  fi
  k create namespace "${MONITORING_NAMESPACE}" >/dev/null
  ok "created"
}

ensure_grafana_secret() {
  step "Grafana Secret ${GRAFANA_SECRET}"
  if k -n "${MONITORING_NAMESPACE}" get secret "${GRAFANA_SECRET}" >/dev/null 2>&1; then
    ok "exists, left unchanged"
    return
  fi
  local password
  password="$(security find-generic-password -s "${GRAFANA_KEYCHAIN_SERVICE}" -a admin -w 2>/dev/null || true)"
  if [[ -n "${password}" ]]; then
    ok "password read from macOS Keychain (${GRAFANA_KEYCHAIN_SERVICE})"
  else
    password="$(openssl rand -hex 16)"
    security add-generic-password -s "${GRAFANA_KEYCHAIN_SERVICE}" -a admin -w "${password}"
    ok "new password generated and stored in macOS Keychain (${GRAFANA_KEYCHAIN_SERVICE})"
  fi
  k -n "${MONITORING_NAMESPACE}" create secret generic "${GRAFANA_SECRET}" \
    --from-env-file=<(printf 'admin-user=admin\nadmin-password=%s\n' "${password}") >/dev/null
  unset password
  k -n "${MONITORING_NAMESPACE}" label secret "${GRAFANA_SECRET}" app.kubernetes.io/managed-by=bootstrap-local >/dev/null
  ok "created (value not printed)"
}

apply_applications() {
  step "Argo CD Applications"
  local file
  APPLICATIONS=()
  for file in "${ROOT}"/argocd/*.yaml; do
    [[ -f "${file}" ]] || die "no Application manifests found in ${ROOT}/argocd"
    APPLICATIONS+=("$(k apply -f "${file}" -o name)")
    ok "${file#"${ROOT}"/}"
  done
}

wait_for_sync() {
  step "Waiting for Argo CD to sync"
  local app
  for app in "${APPLICATIONS[@]}"; do
    k -n argocd wait "${app}" --for=jsonpath='{.status.sync.status}'=Synced --timeout="${TIMEOUT}" >/dev/null
    ok "${app#*/} Synced"
  done
}

wait_for_postgres() {
  step "PostgreSQL"
  k -n "${APP_NAMESPACE}" rollout status "statefulset/${DB_STATEFULSET}" --timeout="${TIMEOUT}" >/dev/null
  k -n "${APP_NAMESPACE}" wait "pvc/${DB_PVC}" --for=jsonpath='{.status.phase}'=Bound --timeout="${TIMEOUT}" >/dev/null
  ok "StatefulSet ready, PVC ${DB_PVC} Bound"
}

psql_exec() {
  # shellcheck disable=SC2016 # $POSTGRES_USER/$POSTGRES_DB must expand inside the pod, not locally.
  k -n "${APP_NAMESPACE}" exec -i "statefulset/${DB_STATEFULSET}" -- \
    sh -c 'PGOPTIONS="-c client_min_messages=warning" exec psql -v ON_ERROR_STOP=1 -q -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' psql "$@"
}

run_migrations() {
  step "Schema migrations"
  psql_exec -c 'CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())'
  local applied file version count=0
  applied="$(psql_exec -tA -c 'SELECT version FROM schema_migrations')"
  for file in "${MIGRATIONS}"/*.sql; do
    [[ -f "${file}" ]] || die "no migration files found in ${MIGRATIONS}"
    version="$(basename "${file}")"
    [[ "${version}" =~ ^[0-9]{3}_[a-z0-9_]+\.sql$ ]] || die "invalid migration file name: ${version}"
    if grep -qx "${version}" <<<"${applied}"; then
      continue
    fi
    { echo 'BEGIN;'; cat "${file}"; printf "INSERT INTO schema_migrations (version) VALUES ('%s');\nCOMMIT;\n" "${version}"; } | psql_exec
    ok "applied ${version}"
    count=$((count + 1))
  done
  [[ "${count}" -gt 0 ]] || ok "nothing to apply"
}

wait_for_app() {
  step "Task API"
  k -n "${APP_NAMESPACE}" rollout status "deployment/${APP_DEPLOYMENT}" --timeout="${TIMEOUT}" >/dev/null
  local app
  for app in "${APPLICATIONS[@]}"; do
    k -n argocd wait "${app}" --for=jsonpath='{.status.health.status}'=Healthy --timeout="${TIMEOUT}" >/dev/null
    ok "${app#*/} Healthy"
  done
}

check_endpoints() {
  step "Health endpoints"
  k -n "${APP_NAMESPACE}" port-forward "svc/${APP_DEPLOYMENT}" 18080:80 >/dev/null 2>&1 &
  PF_PID=$!
  local path
  for path in /health/live /health/ready; do
    curl -fs --retry 10 --retry-connrefused --retry-delay 1 "http://127.0.0.1:18080${path}" >/dev/null ||
      die "GET ${path} did not return 200 through the Service port-forward"
    ok "GET ${path} -> 200"
  done
  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  PF_PID=""

  if ! k -n "${APP_NAMESPACE}" get deployment "${UI_DEPLOYMENT}" >/dev/null 2>&1; then
    ok "web UI not deployed yet, skipped"
    return
  fi
  k -n "${APP_NAMESPACE}" rollout status "deployment/${UI_DEPLOYMENT}" --timeout="${TIMEOUT}" >/dev/null
  k -n "${APP_NAMESPACE}" port-forward "svc/${UI_DEPLOYMENT}" 18081:80 >/dev/null 2>&1 &
  PF_PID=$!
  for path in /healthz / /api/tickets/stats; do
    curl -fs --retry 10 --retry-connrefused --retry-delay 1 "http://127.0.0.1:18081${path}" >/dev/null ||
      die "web UI: GET ${path} did not return 200"
    ok "web UI GET ${path} -> 200"
  done
  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  PF_PID=""
}

summary() {
  step "Summary"
  printf '    %-22s %s\n' \
    "Argo CD" "$(k -n argocd get deployment argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}')" \
    "Task API image" "$(k -n "${APP_NAMESPACE}" get deployment "${APP_DEPLOYMENT}" -o jsonpath='{.spec.template.spec.containers[0].image}')" \
    "PostgreSQL" "$(k -n "${APP_NAMESPACE}" get statefulset "${DB_STATEFULSET}" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready')" \
    "PVC ${DB_PVC}" "$(k -n "${APP_NAMESPACE}" get pvc "${DB_PVC}" -o jsonpath='{.status.phase}, {.status.capacity.storage}')"
  cat <<EOF

    Note: migrations recreate the schema, not the data. There is no backup/restore; if the
    cluster was reset, the database started empty.

    Web UI:     kubectl --context ${CONTEXT} -n ${APP_NAMESPACE} port-forward svc/${UI_DEPLOYMENT} 8080:80
    API:        kubectl --context ${CONTEXT} -n ${APP_NAMESPACE} port-forward svc/${APP_DEPLOYMENT} 8081:80
    Argo CD:    kubectl --context ${CONTEXT} -n argocd port-forward svc/argocd-server 8443:443
    Prometheus: kubectl --context ${CONTEXT} -n ${MONITORING_NAMESPACE} port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
    Grafana:    kubectl --context ${CONTEXT} -n ${MONITORING_NAMESPACE} port-forward svc/monitoring-grafana 3000:80
                (user admin, password: security find-generic-password -s ${GRAFANA_KEYCHAIN_SERVICE} -w)
EOF
}

check_prerequisites
check_cluster
if [[ "${MODE}" == "full" ]]; then
  check_gitops_repo
fi
install_argocd
ensure_app_namespace
ensure_db_secret
ensure_monitoring_namespace
ensure_grafana_secret
if [[ "${MODE}" == "prepare" ]]; then
  printf '\nPrepare finished: Argo CD, namespaces and Secrets are in place.\n'
  printf 'Push the GitOps changes, then run %s without --prepare.\n' "$0"
  exit 0
fi
apply_applications
wait_for_sync
wait_for_postgres
run_migrations
wait_for_app
check_endpoints
summary
