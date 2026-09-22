#!/usr/bin/env bash
# probe.sh — the observation library.
#
# The six hand-written scenario paths each hardcode what to measure, which is why a new kind
# of customer issue needed a new function in a driver. A probe is that measurement pulled out
# as data: a named observation that can be taken before a fault and again after it, on any
# product, without the flow knowing what it means.
#
# Contract for every probe_* function:
#   * echoes ONE line: a scalar value, or the literal UNKNOWN
#   * never aborts the run — a probe that cannot be taken is UNKNOWN, not a failure. Under
#     `set -e` an aborting probe would kill the run mid-measurement and lose the package.
#   * writes whatever it read to $PKG/evidence/$PROBE_PHASE/ so the value is auditable
#
# UNKNOWN is load-bearing. It is what makes the engine return INCONCLUSIVE instead of
# inventing NOT REPRODUCED out of a probe that never ran — rule 3, applied to the
# instruments rather than to the product.

PROBE_PHASE="${PROBE_PHASE:-before}"

# Where a probe parks its raw output. Sanitised: a probe id reaches a filename.
probe_evidence_path() {
  local id; id="$(slugify "$1")"
  local dir="$PKG/evidence/$PROBE_PHASE"
  mkdir -p "$dir"
  printf '%s/probe-%s.txt' "$dir" "$id"
}

# --- HTTP --------------------------------------------------------------------

# probe_http_status <id> <url> [extra curl args...]
#   -> the HTTP status code, or UNKNOWN when nothing answered
# The extra args exist for authentication: Data Grid's properties realm is digest, so a
# probe against it needs `--digest -u user:pass` and a Basic-auth probe would read 401 as a
# product finding.
probe_http_status() {
  local id="$1" url="$2"; shift 2
  local out code
  out="$(probe_evidence_path "$id")"
  code="$(curl -s -o "$out.body" -w '%{http_code}' --max-time 15 "$@" "$url" 2>"$out.err" || true)"
  {
    printf 'url    : %s\n' "$url"
    printf 'status : %s\n' "${code:-none}"
    printf -- '--- body (first 2k) ---\n'
    head -c 2048 "$out.body" 2>/dev/null || true
  } >"$out"
  rm -f "$out.err"
  # curl prints 000 when it never got a response. That is not a status, it is an absence.
  if [[ -z "$code" || "$code" == "000" ]]; then printf 'UNKNOWN'; else printf '%s' "$code"; fi
}

# probe_http_match <id> <url> <regex> [extra curl args...]   -> yes | no | UNKNOWN
probe_http_match() {
  local id="$1" url="$2" re="$3"; shift 3
  local out code
  out="$(probe_evidence_path "$id")"
  code="$(curl -s -o "$out.body" -w '%{http_code}' --max-time 15 "$@" "$url" 2>/dev/null || true)"
  {
    printf 'url    : %s\npattern: %s\nstatus : %s\n' "$url" "$re" "${code:-none}"
    printf -- '--- body (first 2k) ---\n'
    head -c 2048 "$out.body" 2>/dev/null || true
  } >"$out"
  if [[ -z "$code" || "$code" == "000" ]]; then printf 'UNKNOWN'; return 0; fi
  if grep -qE -- "$re" "$out.body" 2>/dev/null; then printf 'yes'; else printf 'no'; fi
}

# --- logs --------------------------------------------------------------------

# probe_log_count <id> <regex>   -> how many times the pattern appears across every log this
# run produced. The customer's error code is the most common thing a case actually states,
# so this is the probe that the largest number of unseen cases will lean on.
probe_log_count() {
  local id="$1" re="$2" out n
  out="$(probe_evidence_path "$id")"
  local -a files=()
  local f
  for f in "$PKG"/nodes/*/log/*.log "$PKG"/logs/*.log "$PKG"/logs/*.txt; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if (( ${#files[@]} == 0 )); then
    printf 'pattern: %s\n(no log files exist yet)\n' "$re" >"$out"
    printf 'UNKNOWN'; return 0
  fi
  n="$(grep -hcE -- "$re" "${files[@]}" 2>/dev/null | awk '{s+=$1} END{print s+0}' || true)"
  {
    printf 'pattern: %s\ncount  : %s\nfiles  : %s\n' "$re" "${n:-0}" "${#files[@]}"
    printf -- '--- matching lines (first 40) ---\n'
    grep -hE -- "$re" "${files[@]}" 2>/dev/null | head -40 || true
  } >"$out"
  printf '%s' "${n:-0}"
}

# --- clustering ---------------------------------------------------------------

# probe_cluster_view <id> <node-index>   -> members in the newest view that node logged
probe_cluster_view() {
  local id="$1" idx="${2:-0}" out n node log
  out="$(probe_evidence_path "$id")"
  node="$(probe_node_name "$idx")"
  log="$PKG/nodes/$node/log/server.log"
  [[ -f "$log" ]] || log="$PKG/nodes/$node/log/server.log.0"
  if [[ ! -f "$log" ]]; then
    printf 'no server.log for node index %s (%s)\n' "$idx" "$node" >"$out"
    printf 'UNKNOWN'; return 0
  fi
  # view_size already knows that counting commas is wrong (the timestamp and the view id
  # both contribute commas) — do not reimplement it here.
  n="$(view_size "$log" 2>/dev/null || true)"
  {
    printf 'node : %s\nlog  : %s\nview : %s\n' "$node" "$log" "${n:-UNKNOWN}"
    printf -- '--- view lines (last 10) ---\n'
    grep -hE 'ISPN000094|WFLYCLJG0033|Received new cluster view|x-site view' "$log" 2>/dev/null | tail -10 || true
  } >"$out"
  if [[ -z "${n:-}" || "$n" == "0" ]]; then printf 'UNKNOWN'; else printf '%s' "$n"; fi
}

# Node names differ per driver; ask whichever one is loaded.
probe_node_name() {
  local idx="$1"
  if declare -p EAP_NODES >/dev/null 2>&1; then printf '%s' "${EAP_NODES[$idx]}"; return 0; fi
  if declare -p DG_NODES  >/dev/null 2>&1; then printf '%s' "${DG_NODES[$idx]}";  return 0; fi
  printf 'node%s' "$((idx+1))"
}

# --- management API ------------------------------------------------------------

# probe_mgmt_attr <id> <address> <attribute> [node-index]
#   e.g. probe_mgmt_attr pool /subsystem=datasources/data-source=ExampleDS/statistics=pool \
#                             InUseCount
# This is the probe that makes connection-pool, transaction and thread-pool cases measurable
# without a new driver function: nearly every EAP runtime number is readable this way.
probe_mgmt_attr() {
  local id="$1" addr="$2" attr="$3" idx="${4:-0}" out port raw val
  out="$(probe_evidence_path "$id")"
  if ! declare -p EAP_MGMT >/dev/null 2>&1; then
    printf 'no management ports known (not an EAP run)\n' >"$out"; printf 'UNKNOWN'; return 0
  fi
  port="${EAP_MGMT[$idx]}"
  if [[ ! -x "${EAP_HOME:-}/bin/jboss-cli.sh" ]]; then
    printf 'jboss-cli.sh not available\n' >"$out"; printf 'UNKNOWN'; return 0
  fi
  raw="$("$EAP_HOME/bin/jboss-cli.sh" --connect --controller="$WS_BIND:$port" \
          --command="${addr}:read-attribute(name=${attr})" 2>&1 || true)"
  printf 'address  : %s\nattribute: %s\ncontroller: %s:%s\n--- raw ---\n%s\n' \
         "$addr" "$attr" "$WS_BIND" "$port" "$raw" >"$out"
  grep -q '"outcome" => "success"' <<<"$raw" || { printf 'UNKNOWN'; return 0; }
  val="$(grep -oE '"result" => .*' <<<"$raw" | head -1 | sed -E 's/"result" => //; s/^"//; s/"$//; s/[[:space:]]+$//' || true)"
  # An attribute that exists but is undefined is not a number and must not be compared as one.
  [[ -z "$val" || "$val" == "undefined" ]] && { printf 'UNKNOWN'; return 0; }
  printf '%s' "$val"
}

# --- TLS -----------------------------------------------------------------------

# probe_tls_handshake <id> <host> <port> [protocol]   -> ok | fail | UNKNOWN
# protocol is passed through to openssl verbatim: tls1_2, tls1_3, ...
probe_tls_handshake() {
  local id="$1" host="$2" port="$3" proto="${4:-}" out raw
  out="$(probe_evidence_path "$id")"
  if ! have openssl; then
    printf 'openssl not installed — cannot measure a handshake\n' >"$out"
    printf 'UNKNOWN'; return 0
  fi
  local -a args=(s_client -connect "$host:$port" -brief)
  [[ -n "$proto" ]] && args+=("-$proto")
  raw="$(printf 'Q\n' | timeout 20 openssl "${args[@]}" 2>&1 || true)"
  printf 'host: %s:%s\nprotocol: %s\n--- openssl ---\n%s\n' "$host" "$port" "${proto:-default}" "$raw" >"$out"
  if grep -qiE 'handshake failure|no cipher|alert|unable to get|connect:errno|refused' <<<"$raw"; then
    printf 'fail'
  elif grep -qiE 'Protocol version|Ciphersuite|CONNECTION ESTABLISHED|Verification' <<<"$raw"; then
    printf 'ok'
  else
    printf 'UNKNOWN'
  fi
}

# --- JVM -------------------------------------------------------------------------

# A JVM probe is addressed either by an argv marker (EAP/Data Grid nodes) or by a pid the
# driver already recorded (the JVM workload). java_pid_for exists because
# `pgrep -f "<marker>" | head -1` returns the wrapper shell, not the JVM.
probe_resolve_pid() {
  local who="$1"
  if [[ "$who" =~ ^[0-9]+$ ]]; then
    ps -p "$who" >/dev/null 2>&1 && printf '%s' "$who"
    return 0
  fi
  java_pid_for "$who" || true
}

# probe_thread_deadlock <id> <argv-marker|pid>   -> number of Java-level deadlocks found
probe_thread_deadlock() {
  local id="$1" marker="$2" out pid raw n
  out="$(probe_evidence_path "$id")"
  pid="$(probe_resolve_pid "$marker")"
  if [[ -z "$pid" ]]; then
    printf 'no java process matching: %s\n' "$marker" >"$out"; printf 'UNKNOWN'; return 0
  fi
  raw="$(timeout 30 jcmd "$pid" Thread.print 2>&1 || true)"
  printf '%s\n' "$raw" >"$out"
  n="$(grep -cE 'Found [0-9]+ Java-level deadlock|Found one Java-level deadlock' <<<"$raw" || true)"
  printf '%s' "${n:-0}"
}

# probe_heap_used_after_gc <id> <argv-marker|pid>   -> KB still used after a forced full GC.
# A retention problem is only visible AFTER a collection; sampling live heap measures
# allocation rate instead and will call any busy application a leak.
probe_heap_used_after_gc() {
  local id="$1" marker="$2" out pid raw kb
  out="$(probe_evidence_path "$id")"
  pid="$(probe_resolve_pid "$marker")"
  if [[ -z "$pid" ]]; then
    printf 'no java process matching: %s\n' "$marker" >"$out"; printf 'UNKNOWN'; return 0
  fi
  timeout 60 jcmd "$pid" GC.run >/dev/null 2>&1 || true
  raw="$(timeout 30 jcmd "$pid" GC.heap_info 2>&1 || true)"
  printf '%s\n' "$raw" >"$out"
  kb="$(grep -oE 'used [0-9]+K' <<<"$raw" | head -1 | grep -oE '[0-9]+' || true)"
  if [[ -z "$kb" ]]; then printf 'UNKNOWN'; else printf '%s' "$kb"; fi
}

# --- process / port ----------------------------------------------------------------

# probe_port <id> <host> <port>   -> open | closed
probe_port() {
  local id="$1" host="$2" port="$3" out
  out="$(probe_evidence_path "$id")"
  if port_open "$host" "$port"; then
    printf '%s:%s open\n' "$host" "$port" >"$out"; printf 'open'
  else
    printf '%s:%s closed\n' "$host" "$port" >"$out"; printf 'closed'
  fi
}

# --- dispatcher ---------------------------------------------------------------------

# probe_take <id> <kind> [args...]   -> the value, echoed
# An unknown kind is UNKNOWN rather than an error: a plan naming a probe this build does not
# have should degrade to INCONCLUSIVE, not abort a run that has already started servers.
probe_take() {
  local id="$1" kind="$2"; shift 2
  case "$kind" in
    http_status)        probe_http_status        "$id" "$@" ;;
    http_match)         probe_http_match         "$id" "$@" ;;
    log_count)          probe_log_count          "$id" "$@" ;;
    cluster_view)       probe_cluster_view       "$id" "$@" ;;
    mgmt_attr)          probe_mgmt_attr          "$id" "$@" ;;
    tls_handshake)      probe_tls_handshake      "$id" "$@" ;;
    thread_deadlock)    probe_thread_deadlock    "$id" "$@" ;;
    heap_used_after_gc) probe_heap_used_after_gc "$id" "$@" ;;
    port)               probe_port               "$id" "$@" ;;
    *) warn "unknown probe kind '$kind' (id=$id) — recorded as UNKNOWN"
       printf 'UNKNOWN' ;;
  esac
}

# The vocabulary, in one place. lib/plan.sh validates against this, and the LLM prompt is
# built from it, so adding a probe above and its name here is the whole extension step.
PROBE_KINDS="http_status http_match log_count cluster_view mgmt_attr tls_handshake thread_deadlock heap_used_after_gc port"
export PROBE_KINDS
