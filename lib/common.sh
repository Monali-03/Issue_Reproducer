#!/usr/bin/env bash
# common.sh — shared helpers for every product workspace.
# Sourced by lib/<product>.sh and by each workspace's run.sh.

set -euo pipefail

REPRO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$REPRO_ROOT/lib"
TEMPLATES_DIR="$REPRO_ROOT/templates"
export REPRO_ROOT LIB_DIR TEMPLATES_DIR

# --- output -----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_BLU=$'\e[34m'; C_OFF=$'\e[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_OFF=""
fi

ts() { date -Is; }

_log() {
  local lvl="$1" col="$2"; shift 2
  printf '%s[%s] %-5s %s%s\n' "$col" "$(ts)" "$lvl" "$*" "$C_OFF"
  [[ -n "${REPRO_LOG:-}" ]] && printf '[%s] %-5s %s\n' "$(ts)" "$lvl" "$*" >>"$REPRO_LOG"
  return 0
}
info() { _log INFO  "$C_BLU" "$@"; }
ok()   { _log OK    "$C_GRN" "$@"; }
warn() { _log WARN  "$C_YEL" "$@" >&2; }
step() { printf '\n%s=== %s ===%s\n' "$C_BLU" "$*" "$C_OFF"
         [[ -n "${REPRO_LOG:-}" ]] && printf '\n=== %s ===\n' "$*" >>"$REPRO_LOG"; return 0; }
die()  { _log FATAL "$C_RED" "$@" >&2; exit 1; }

# BLOCKED is a first-class outcome: the reproduction could not be executed. It is not a
# statement about the product, and must never be reported as "not reproduced".
blocked() {
  _log BLOCK "$C_YEL" "$@" >&2
  [[ -n "${PKG:-}" ]] && echo "BLOCKED: $*" >"$PKG/VERDICT.txt"
  exit 4
}

# --- command logging --------------------------------------------------------
# Every command against the environment is recorded so the run can be replayed.
run_cmd() {
  local label="$1"; shift
  local rc=0 out
  [[ -n "${COMMANDS_LOG:-}" ]] && {
    printf '[%s] [%s]\nCOMMAND: %s\n' "$(ts)" "$label" "$*" >>"$COMMANDS_LOG"; }
  out="$("$@" 2>&1)" || rc=$?
  [[ -n "${COMMANDS_LOG:-}" ]] && {
    printf 'EXIT:    %s\n' "$rc" >>"$COMMANDS_LOG"
    [[ -n "$out" ]] && printf 'OUTPUT:  %s\n' "$(head -20 <<<"$out")" >>"$COMMANDS_LOG"
    printf '\n' >>"$COMMANDS_LOG"; }
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return "$rc"
}

# --- safety -----------------------------------------------------------------
# Destructive operations are confined to the run's own package directory.
assert_in_pkg() {
  local p="${1:-}"
  [[ -n "$p" ]] || die "refusing: empty path (unset variable?)"
  [[ -n "${PKG:-}" ]] || die "refusing: PKG is not set"
  case "$(realpath -m "$p")" in
    "$(realpath -m "$PKG")"/*) return 0 ;;
    *) die "refusing to operate outside the package: $p" ;;
  esac
}

# Kill only a PID this run recorded, and only while its argv still identifies it.
# A broad pattern (pkill -f java) would kill the user's IDE — there is no safe form.
kill_recorded_pid() {
  local pidfile="$1" argv_match="$2" sig="${3:-TERM}" pid
  [[ -f "$pidfile" ]] || { warn "no pidfile $pidfile"; return 0; }
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] || { warn "empty pidfile $pidfile"; return 0; }
  if ! ps -p "$pid" >/dev/null 2>&1; then
    info "pid $pid already gone"; rm -f "$pidfile"; return 0
  fi
  if ! ps -p "$pid" -o args= 2>/dev/null | grep -Fq -- "$argv_match"; then
    die "pid $pid no longer matches '$argv_match' — refusing to kill (PID reuse)"
  fi
  [[ -n "${COMMANDS_LOG:-}" ]] && printf \
    '[%s] DESTRUCTIVE\n  kill -%s %s\n  target: %s\n  authorized: started by this run (%s)\n\n' \
    "$(ts)" "$sig" "$pid" "$argv_match" "$pidfile" >>"$COMMANDS_LOG"
  info "kill -$sig $pid ($argv_match)"
  kill "-$sig" "$pid" 2>/dev/null || true
  rm -f "$pidfile"
}

# --- waiting ----------------------------------------------------------------
# Poll for the condition with a bounded timeout. Never `sleep 30` and hope.
# `set -e` aborts silently by design. In a driver this size that means a run can end between
# two log lines with nothing to say why — which is exactly what an unguarded `grep` or a
# trailing `[[ ]]` test produces. errtrace + an ERR trap name the command before the unwind.
set -E
trap 'REPRO_RC=$?; printf "\n[FATAL] %s:%s exited %s while running: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$REPRO_RC" "$BASH_COMMAND" >&2' ERR

# PID of the java process carrying a marker in its argv.
#
# Not `pgrep -f "$marker" | head -1`: standalone.sh / server.sh pass the same marker through
# to the JVM, so the wrapper shell matches too and — having started first — wins the lowest
# PID. Signalling the wrapper leaves the server up, and the run then measures a node it
# believes it killed.
java_pid_for() {
  local marker="$1" p comm
  for p in $(pgrep -f -- "$marker" 2>/dev/null || true); do
    comm="$(ps -p "$p" -o comm= 2>/dev/null || true)"
    if [[ "$comm" == "java" ]]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# The connect attempt happens in a subshell, so the descriptor it opens dies with it and
# there is nothing for the caller to clean up. An `exec 3>&- 2>/dev/null` here would not
# just close fd 3: `exec` with redirections and no command applies them to THIS shell, so
# every error message and xtrace line after the first successful port check would be
# discarded — which is how a run ends between two log lines with no reason given.
port_open() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; }

wait_for_port() {
  local host="$1" port="$2" timeout="${3:-120}" i=0
  while (( i < timeout )); do port_open "$host" "$port" && return 0; sleep 1; ((i++)); done
  return 1
}
wait_for_port_closed() {
  local host="$1" port="$2" timeout="${3:-60}" i=0
  while (( i < timeout )); do port_open "$host" "$port" || return 0; sleep 1; ((i++)); done
  return 1
}
# grep inside a wait loop matches nothing on most iterations — which aborts the script
# under `set -e` unless every such call is guarded. Hence `|| true` throughout.
wait_for_log() {
  local file="$1" pattern="$2" timeout="${3:-180}" i=0
  while (( i < timeout )); do
    [[ -f "$file" ]] && grep -Eq -- "$pattern" "$file" 2>/dev/null && return 0
    sleep 1; ((i++))
  done
  return 1
}
wait_for_http() {
  local url="$1" want="${2:-200}" timeout="${3:-120}" i=0 got
  while (( i < timeout )); do
    got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    [[ "$got" == "$want" ]] && return 0
    sleep 1; ((i++))
  done
  return 1
}
# `grep -c` prints 0 AND exits 1 when nothing matches: both halves need handling.
# Number of members in an Infinispan/JGroups cluster-view line.
#
# Counting commas across the whole line is wrong twice over: the log timestamp
# ("15:14:44,619") and the view id both contribute commas, so a cluster of one can be
# reported as three and sail through the formation gate.
view_size() {
  local line="$1" n="" members=""
  # ISPN000094 states the size: "... [node2|1] (2) [node2, node1]".
  n="$(sed -nE 's/.*\|[0-9]+\][[:space:]]*\(([0-9]+)\).*/\1/p' <<<"$line" | head -1)"
  if [[ -z "$n" ]]; then
    # Infinispan rebalance lines name the members mid-line: "with members [node1, node2],".
    members="$(sed -nE 's/.*members[[:space:]]*\[([^][]*)\].*/\1/p' <<<"$line" | head -1)"
    # Otherwise count a trailing member list.
    [[ -z "$members" ]] && members="$(sed -nE 's/.*\[([^][]*)\][[:space:]]*$/\1/p' <<<"$line" | head -1)"
    [[ -n "$members" ]] && n="$(tr ',' '\n' <<<"$members" | grep -c '[^[:space:]]' || true)"
  fi
  printf '%s' "${n:-0}"
}

count_matches() { local n; n="$(grep -Ec -- "$2" "$1" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

# --- JDK resolution ---------------------------------------------------------
# Never silently fall back to whatever `java` happens to be: an unsupported JDK makes the
# server die at boot for reasons unrelated to the customer's issue.
jdk_major() {
  local j="$1" v
  v="$("$j/bin/java" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+)\.?([0-9]*).*/\1 \2/')"
  set -- $v
  [[ "$1" == "1" ]] && { echo "$2"; return; }
  echo "$1"
}

resolve_jdk() {
  local want="$1" cand
  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    [[ "$(jdk_major "$JAVA_HOME")" == "$want" ]] && { echo "$JAVA_HOME"; return 0; }
  fi
  for cand in /usr/lib/jvm/*/ "$HOME"/jdks/*/ /opt/jdk*/ /opt/java/*/; do
    cand="${cand%/}"
    [[ -x "$cand/bin/java" ]] || continue
    [[ "$(jdk_major "$cand" 2>/dev/null)" == "$want" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

# Returns 0 even when the last candidate does not exist. A `dir/*/` glob that matches
# nothing expands to itself, the -x test then fails, and the function's exit status becomes
# that failure — which under `set -e` kills the caller in the middle of a diagnostic.
list_jdks() {
  local cand
  for cand in /usr/lib/jvm/*/ "$HOME"/jdks/*/ /opt/jdk*/ /opt/java/*/; do
    cand="${cand%/}"
    [[ -x "$cand/bin/java" ]] || continue
    printf '  %-56s java %s\n' "$cand" "$(jdk_major "$cand" 2>/dev/null || echo '?')"
  done
  return 0
}

# --- port isolation between workspaces --------------------------------------
# Each workspace owns a disjoint port block (see its workspace.env) so two products can
# run at the same time without interfering.
assert_ports_free() {
  local p busy=""
  for p in "$@"; do port_open "$WS_BIND" "$p" && busy+=" $p"; done
  [[ -z "$busy" ]] && return 0
  die "ports in use:$busy
       Another run is still up. Use ./run.sh --clean in the owning workspace.
       These ports belong to the '$WS_NAME' workspace only; other products use other blocks."
}

# Cross-workspace lock: refuses to start a second run of the SAME workspace, while
# leaving the other three free to run concurrently.
acquire_ws_lock() {
  local lock="$WS_DIR/.run.lock" old
  if [[ -f "$lock" ]]; then
    old="$(cat "$lock" 2>/dev/null || true)"
    if [[ -n "$old" ]] && ps -p "$old" >/dev/null 2>&1; then
      die "workspace '$WS_NAME' is already running (pid $old). Wait, or ./run.sh --clean."
    fi
    warn "stale lock from pid $old — taking over"
  fi
  echo $$ >"$lock"
  # shellcheck disable=SC2064
  trap "rm -f '$lock'" EXIT
}

# --- misc -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

slugify() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40; }

human_size() { local b="$1"; if (( b > 1048576 )); then echo "$((b/1048576))M"; elif (( b > 1024 )); then echo "$((b/1024))K"; else echo "${b}B"; fi; }
