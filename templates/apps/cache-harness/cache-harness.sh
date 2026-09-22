#!/usr/bin/env bash
# cache-harness.sh — automatic cache exercise for Red Hat Data Grid / Infinispan server.
#
# Creates the cache, writes N entries, reads every one back from EVERY node, and reports
# per-node hit/miss. This is the Data Grid equivalent of the session probe: it exists so a
# failover verdict is decidable from data rather than inferred from logs.
#
#   ./cache-harness.sh create                create (or recreate) the cache
#   ./cache-harness.sh put [N]               write N entries (default $ENTRY_COUNT)
#   ./cache-harness.sh verify                read every entry from every node
#   ./cache-harness.sh verify --node host:port   read from one node only
#   ./cache-harness.sh stats                 per-node entry counts and cache stats
#   ./cache-harness.sh members               cluster membership as each node sees it
#   ./cache-harness.sh destroy               remove the cache
#   ./cache-harness.sh all                   create + put + verify   (the usual path)
#
# Config comes from nodes.env, overridable by environment.

set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Locate the package root by walking up to the nodes.env that owns this run. The harness
# lives at $PKG/app/ once generated but at templates/apps/cache-harness/ in the repo, so a
# fixed number of ".." is wrong in one of the two places — and writing reports into the
# template tree is how a run's output ends up outside its own package.
PKG_ROOT="$HERE"
while [[ "$PKG_ROOT" != "/" && ! -f "$PKG_ROOT/nodes.env" ]]; do
  PKG_ROOT="$(dirname "$PKG_ROOT")"
done
if [[ -f "$PKG_ROOT/nodes.env" ]]; then
  # shellcheck source=/dev/null
  source "$PKG_ROOT/nodes.env"
else
  PKG_ROOT="$HERE"          # standalone use: keep everything beside the script
fi

DG_HOSTS="${DG_HOSTS:-127.0.0.1:11222 127.0.0.1:11322 127.0.0.1:11422}"
DG_USER="${DG_USER:-admin}"
DG_PASS="${DG_PASS:-password}"
CACHE_NAME="${CACHE_NAME:-reprocache}"
ENTRY_COUNT="${ENTRY_COUNT:-100}"
CACHE_CONFIG="${CACHE_CONFIG:-$HERE/cache-config.json}"
OUT_DIR="${OUT_DIR:-$PKG_ROOT/output}"
mkdir -p "$OUT_DIR"

first_host() { set -- $DG_HOSTS; echo "$1"; }

# ---------------------------------------------------------------------------
# Authentication.
#
# Data Grid's default properties realm stores only HASHED credentials, so Basic auth is
# rejected even when the username and password are correct. Digest is what the server
# actually negotiates. `curl --digest` handles either, so it is the safe default here.
#
# The trap this guards against: /health/status typically answers ANONYMOUSLY. A readiness
# probe against it reports HEALTHY while every real cache call returns 403 -- and the
# harness then records those 403s as "key missing" and reports a replication bug that does
# not exist. So auth is proven against a REAL cache operation before anything is measured.
# ---------------------------------------------------------------------------
rest() {
  local method="$1" host="$2" path="$3"; shift 3
  curl -sS --digest -u "$DG_USER:$DG_PASS" \
       -X "$method" --max-time 15 -w '\n%{http_code}' \
       "http://$host$path" "$@" 2>/dev/null || printf '\n000'
}

# Split the combined body/status that `rest` returns.
body_of()   { sed '$d' <<<"$1"; }
status_of() { tail -1 <<<"$1"; }

assert_auth() {
  local host="$1" r s
  r="$(rest GET "$host" "/rest/v2/caches")"
  s="$(status_of "$r")"
  case "$s" in
    200) return 0 ;;
    401|403)
      echo "FATAL: authentication rejected by $host (HTTP $s)." >&2
      echo "  The credentials are wrong, or the realm does not accept this mechanism." >&2
      echo "  Do NOT interpret later 404s as missing entries -- they would be auth" >&2
      echo "  failures. This run is INCONCLUSIVE, not a reproduction." >&2
      return 1 ;;
    000)
      echo "FATAL: $host unreachable." >&2; return 1 ;;
    *)
      echo "FATAL: unexpected status $s from $host on /rest/v2/caches" >&2; return 1 ;;
  esac
}

# --- operations -------------------------------------------------------------

cmd_create() {
  local host; host="$(first_host)"
  assert_auth "$host" || exit 2

  # REST-created caches are PERMANENT -- they survive restarts. Re-running the harness
  # against a surviving cache silently inherits the previous run's entries, which makes
  # the next verify meaningless. So always delete first and ignore "not found".
  echo "== destroying any existing '$CACHE_NAME'"
  rest DELETE "$host" "/rest/v2/caches/$CACHE_NAME" >/dev/null || true

  echo "== creating '$CACHE_NAME' from $(basename "$CACHE_CONFIG")"
  local r s
  r="$(rest POST "$host" "/rest/v2/caches/$CACHE_NAME" \
         -H 'Content-Type: application/json' --data-binary "@$CACHE_CONFIG")"
  s="$(status_of "$r")"
  case "$s" in
    200|201|204) echo "   created (HTTP $s)" ;;
    *)
      # A conflict here means the delete did not take effect. Confirm the cache is usable
      # rather than guessing which status code this release uses for "already exists".
      echo "   create returned HTTP $s -- checking whether the cache is usable" >&2
      body_of "$r" | head -3 >&2
      r="$(rest GET "$host" "/rest/v2/caches/$CACHE_NAME")"
      [[ "$(status_of "$r")" == "200" ]] || { echo "FATAL: cache not usable" >&2; exit 2; }
      echo "   cache exists and is usable -- continuing"
      ;;
  esac
}

cmd_put() {
  local n="${1:-$ENTRY_COUNT}" host; host="$(first_host)"
  assert_auth "$host" || exit 2
  echo "== writing $n entries to '$CACHE_NAME' via $host"
  local ok=0 fail=0 i s
  for (( i=1; i<=n; i++ )); do
    s="$(status_of "$(rest POST "$host" "/rest/v2/caches/$CACHE_NAME/key-$i" \
           -H 'Content-Type: text/plain' --data "value-$i")")"
    case "$s" in 200|201|204) ok=$((ok+1)) ;; *) fail=$((fail+1));
      (( fail <= 3 )) && echo "   put key-$i -> HTTP $s" >&2 ;; esac
  done
  echo "   wrote $ok/$n (failed $fail)"
  # Writes that failed are not a replication finding -- they mean nothing was stored to
  # replicate. Treat this as inconclusive, loudly.
  (( fail > 0 )) && { echo "WARN: $fail writes failed -- verify results are INCONCLUSIVE" >&2; exit 3; }
  return 0
}

cmd_verify() {
  local only="" n="$ENTRY_COUNT"
  [[ "${1:-}" == "--node" ]] && only="${2:-}"
  local hosts="${only:-$DG_HOSTS}"
  local report="$OUT_DIR/cache-verify-$(date +%s).txt"
  local total_missing=0

  echo "== verifying $n entries across: $hosts"
  {
    printf 'cache-harness verify  %s\n' "$(date -Is)"
    printf 'cache=%s entries=%s\n\n' "$CACHE_NAME" "$n"
  } >"$report"

  local host hits misses errs i s
  for host in $hosts; do
    if ! assert_auth "$host"; then
      printf '%-24s UNREACHABLE OR AUTH REJECTED -- INCONCLUSIVE\n' "$host" | tee -a "$report"
      total_missing=-1; continue
    fi
    hits=0; misses=0; errs=0
    for (( i=1; i<=n; i++ )); do
      s="$(status_of "$(rest GET "$host" "/rest/v2/caches/$CACHE_NAME/key-$i")")"
      case "$s" in
        200) hits=$((hits+1)) ;;
        404) misses=$((misses+1)) ;;
        # Anything else is neither a hit nor a miss. Counting these as misses is exactly
        # how a harness fault becomes a reported product bug.
        *)   errs=$((errs+1)) ;;
      esac
    done
    printf '%-24s hits=%-5s misses=%-5s errors=%s\n' "$host" "$hits" "$misses" "$errs" \
      | tee -a "$report"
    (( errs > 0 )) && echo "   WARN $host returned $errs non-200/404 statuses -- INCONCLUSIVE" >&2
    total_missing=$(( total_missing + misses ))
  done

  echo "   report: $report"
  if (( total_missing < 0 )); then
    echo "VERDICT: INCONCLUSIVE (node unreachable or auth rejected — NOT a data finding)"
    return 3
  elif (( total_missing == 0 )); then
    echo "VERDICT: all entries readable from every node"; return 0
  else
    echo "VERDICT: $total_missing entry-reads missed -- data not available on every node"
    return 1
  fi
}

cmd_stats() {
  local host
  for host in $DG_HOSTS; do
    echo "== $host"
    body_of "$(rest GET "$host" "/rest/v2/caches/$CACHE_NAME?action=stats")" | head -20
  done
}

cmd_members() {
  # Ask every node independently. A node that sees only itself means the cluster never
  # formed, and every "missing entry" after that is a harness artifact, not a product bug.
  local host
  for host in $DG_HOSTS; do
    printf '%-24s ' "$host"
    body_of "$(rest GET "$host" "/rest/v2/cluster?action=distribution")" | head -5
    echo
  done
}

cmd_destroy() {
  local host; host="$(first_host)"
  rest DELETE "$host" "/rest/v2/caches/$CACHE_NAME" >/dev/null || true
  echo "== destroyed '$CACHE_NAME'"
}

case "${1:-all}" in
  create)  cmd_create ;;
  put)     cmd_put "${2:-}" ;;
  verify)  shift; cmd_verify "$@" ;;
  stats)   cmd_stats ;;
  members) cmd_members ;;
  destroy) cmd_destroy ;;
  all)     cmd_create; cmd_put; cmd_members; cmd_verify ;;
  *) echo "usage: $0 {create|put [N]|verify [--node h:p]|stats|members|destroy|all}" >&2; exit 1 ;;
esac
