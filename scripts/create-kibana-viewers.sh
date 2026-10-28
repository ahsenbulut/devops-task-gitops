#!/usr/bin/env bash
set -euo pipefail

CONTEXT=k3s-local
NAMESPACE=logging
KEYCHAIN_SERVICE=devops-case-kibana-viewers
KEYCHAIN_ACCOUNT=opsdesk-viewers
ES_HOST=opsdesk-es-http.logging.svc
LOCAL_PORT=19200

USERS=(
  "opsdesk-backend-viewer:opsdesk_backend_viewer"
  "opsdesk-frontend-viewer:opsdesk_frontend_viewer"
  "opsdesk-all-viewer:opsdesk_all_viewer"
)

k() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }

read -rsp "Shared test password (min 12 chars): " password; echo
read -rsp "Repeat password: " confirm; echo
[[ "${password}" == "${confirm}" ]] || { echo "Passwords do not match" >&2; exit 1; }
[[ ${#password} -ge 12 ]] || { echo "Password must be at least 12 characters" >&2; exit 1; }
[[ "${password}" != *'"'* && "${password}" != *'\'* ]] || { echo "Password must not contain \" or \\" >&2; exit 1; }
unset confirm

security add-generic-password -U -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${password}"
echo "Password stored in macOS Keychain (${KEYCHAIN_SERVICE})"

workdir="$(mktemp -d)"
k port-forward "svc/opsdesk-es-http" "${LOCAL_PORT}:9200" >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "${pf_pid}" 2>/dev/null || true; rm -rf "${workdir}"' EXIT
sleep 3

k get secret opsdesk-es-http-certs-public -o jsonpath='{.data.ca\.crt}' | base64 -d > "${workdir}/ca.crt"
printf 'user = "elastic:%s"\n' "$(k get secret opsdesk-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)" > "${workdir}/auth"

for entry in "${USERS[@]}"; do
  user="${entry%%:*}"
  role="${entry##*:}"
  printf '{"password":"%s","roles":["%s"]}' "${password}" "${role}" |
    curl -sS --fail-with-body --cacert "${workdir}/ca.crt" --resolve "${ES_HOST}:${LOCAL_PORT}:127.0.0.1" \
      -K "${workdir}/auth" -H 'Content-Type: application/json' \
      -X POST "https://${ES_HOST}:${LOCAL_PORT}/_security/user/${user}" --data-binary @- >/dev/null
  echo "OK  ${user} -> ${role}"
done
unset password
