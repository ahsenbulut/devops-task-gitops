#!/usr/bin/env bash
set -uo pipefail
ES=opsdesk-es-http.logging.svc
KB=opsdesk-kb-http.logging.svc
w="$(mktemp -d)"
kubectl --context k3s-local -n logging port-forward svc/opsdesk-es-http 19200:9200 >/dev/null 2>&1 & p1=$!
kubectl --context k3s-local -n logging port-forward svc/opsdesk-kb-http 15601:5601 >/dev/null 2>&1 & p2=$!
trap 'kill $p1 $p2 2>/dev/null; wait $p1 $p2 2>/dev/null; rm -rf "$w"' EXIT
sleep 4
kubectl --context k3s-local -n logging get secret opsdesk-es-http-certs-public -o jsonpath='{.data.ca\.crt}' | base64 -d > "$w/es.crt"
kubectl --context k3s-local -n logging get secret opsdesk-kb-http-certs-public -o jsonpath='{.data.ca\.crt}' | base64 -d > "$w/kb.crt"
pw="$(security find-generic-password -s devops-case-kibana-viewers -a opsdesk-viewers -w)"

pass=0; fail=0
check() {
  local user="$1" expect="$2" label="$3" method="$4" url="$5" body="${6:-}"
  local ca="$w/es.crt" host="$ES:19200"
  [[ "$url" == /api/* ]] && ca="$w/kb.crt" host="$KB:15601"
  printf 'user = "%s:%s"\n' "$user" "$pw" > "$w/auth"
  local args=(-sS -o "$w/out" -w '%{http_code}' --cacert "$ca" --resolve "${host%:*}:${host#*:}:127.0.0.1" -K "$w/auth" -X "$method" -H 'Content-Type: application/json' -H 'kbn-xsrf: test')
  [[ -n "$body" ]] && args+=(--data-binary "$body")
  local code; code="$(curl "${args[@]}" "https://${host}${url}")"
  local extra=""
  if [[ "$url" == *"_search"* && "$code" == 200 ]]; then
    extra="$(jq -r '[.aggregations.idx.buckets[]? | "\(.key|sub("^\\.ds-";"")|sub("-[0-9.]+-[0-9]+$";""))=\(.doc_count)"] | join(", ")' "$w/out")"
  fi
  local mark="PASS"; if [[ "$code" == "$expect" ]]; then pass=$((pass+1)); else mark="FAIL"; fail=$((fail+1)); fi
  printf '  %-4s %-44s expected %s got %s %s\n' "$mark" "$label" "$expect" "$code" "${extra:+[$extra]}"
}
agg='{"size":0,"aggs":{"idx":{"terms":{"field":"_index"}}}}'
doc='{"@timestamp":"2026-01-01T00:00:00Z","message":"rbac-test"}'
nomatch='{"query":{"term":{"requestId":"rbac-test-no-such-id"}}}'

run_common_negatives() {
  local u="$1"
  check "$u" 403 "write a document"            POST "/opsdesk-logs-backend/_doc" "$doc"
  check "$u" 403 "delete_by_query (matches none)" POST "/opsdesk-logs-frontend/_delete_by_query" "$nomatch"
  check "$u" 403 "delete data stream"          DELETE "/_data_stream/opsdesk-logs-backend"
  check "$u" 403 "read .kibana system index"   GET "/.kibana/_search"
  check "$u" 403 "list all indices (_cat)"     GET "/_cat/indices"
  check "$u" 403 "list users (security API)"   GET "/_security/user"
  check "$u" 403 "Kibana: list roles"          GET "/api/security/role"
  check "$u" 200 "Kibana: read data views"     GET "/api/data_views"
}

echo "== opsdesk-backend-viewer"
check opsdesk-backend-viewer 200 "authenticate"              GET "/_security/_authenticate"
check opsdesk-backend-viewer 200 "search backend"            POST "/opsdesk-logs-backend/_search" "$agg"
check opsdesk-backend-viewer 403 "search frontend"           POST "/opsdesk-logs-frontend/_search" "$agg"
check opsdesk-backend-viewer 200 "search opsdesk-logs-* (only backend)" POST "/opsdesk-logs-*/_search" "$agg"
run_common_negatives opsdesk-backend-viewer

echo "== opsdesk-frontend-viewer"
check opsdesk-frontend-viewer 200 "authenticate"             GET "/_security/_authenticate"
check opsdesk-frontend-viewer 403 "search backend"           POST "/opsdesk-logs-backend/_search" "$agg"
check opsdesk-frontend-viewer 200 "search frontend"          POST "/opsdesk-logs-frontend/_search" "$agg"
check opsdesk-frontend-viewer 200 "search opsdesk-logs-* (only frontend)" POST "/opsdesk-logs-*/_search" "$agg"
run_common_negatives opsdesk-frontend-viewer

echo "== opsdesk-all-viewer"
check opsdesk-all-viewer 200 "authenticate"                  GET "/_security/_authenticate"
check opsdesk-all-viewer 200 "search backend"                POST "/opsdesk-logs-backend/_search" "$agg"
check opsdesk-all-viewer 200 "search frontend"               POST "/opsdesk-logs-frontend/_search" "$agg"
check opsdesk-all-viewer 200 "search opsdesk-logs-* (both)"  POST "/opsdesk-logs-*/_search" "$agg"
run_common_negatives opsdesk-all-viewer

echo "== wrong password"
pw_saved="$pw"; pw="wrong-password-123"
check opsdesk-all-viewer 401 "authenticate with wrong password" GET "/_security/_authenticate"
pw="$pw_saved"; unset pw_saved

echo; echo "RESULT: $pass passed, $fail failed"
unset pw
[[ "$fail" -eq 0 ]]
