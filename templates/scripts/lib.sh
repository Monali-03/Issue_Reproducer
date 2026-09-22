#!/usr/bin/env bash
# Shared helpers for a generated reproducer package.
# Sourced by setup.sh / start.sh / reproduce.sh / collect.sh / cleanup.sh.
#
# Every script sources this and nothing else from outside the package, so the package
# stays self-contained and relocatable.

set -euo pipefail

PKG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PKG_DIR

# shellcheck source=/dev/null
[[ -f "$PKG_DIR/nodes.env" ]] && source "$PKG_DIR/nodes.env"

LOG_DIR="$PKG_DIR/logs"
EVIDENCE_DIR="$PKG_DIR/evidence"
COMMANDS_LOG="$PKG_DIR/commands.log"
REPRO_LOG="$PKG_DIR/reproduction.log"
mkdir -p "$LOG_DIR" "$EVIDENCE_DIR"/{before,during,after} "$PKG_DIR/output"

# --- output ----------------------------------------------------------------

ts()   { date -Is; }
info() { printf '[%s] %s\n'        "$(ts)" "$*" | tee -a "$REPRO_LOG"; }
warn() { printf '[%s] WARN  %s\n'  "$(ts)" "$*" | tee -a "$REPRO_LOG" >&2; }
die()  { printf '[%s] FATAL %s\n'  "$(ts)" "$*" | tee -a "$REPRO_LOG" >&2; exit 1; }

# --- command logging (spec §7) ---------------------------------------------
# run_cmd <terminal-label> <command...>
# Records every command, its exit status and its output location. The command log is
# the replay record: a command that ran and is not in it makes the package a lie.
run_cmd() {
  local label="$1"; shift
  local rc=0 out
  {
    printf '[%s] [%s]\n' "$(ts)" "$label"
    printf 'COMMAND: %s\n' "$*"
  } >>"$COMMANDS_LOG"

  out="$("$@" 2>&1)" || rc=$?

  {
    printf 'EXIT:    %s\n' "$rc"
    [[ -n "$out" ]] && printf 'OUTPUT:  %s\n' "$(printf '%s' "$out" | head -20)"
    printf '\n'
  } >>"$COMMANDS_LOG"

  printf '%s' "$out"
  return "$rc"
}

# --- safety (spec §6, reference/safety-rules.md) ---------------------------

# Refuse to operate on a path outside the package.
assert_in_pkg() {
  local p="${1:-}"
  [[ -n "$p" ]] || die "refusing: empty path (unset variable?)"
  case "$(realpath -m "$p")" in
    "$PKG_DIR"/*) : ;;
    *) die "refusing to operate outside the package: $p" ;;
  esac
}

# Kill only a PID this package started, and only if it is still that process.
# $2 is a string that must appear in the process argv — the guard against PID reuse.
kill_recorded_pid() {
  local pidfile="$1" argv_match="$2" sig="${3:-TERM}" pid
  [[ -f "$pidfile" ]] || { warn "no pidfile $pidfile — nothing to kill"; return 0; }
  pid="$(cat "$pidfile")"
  [[ -n "$pid" ]] || { warn "empty pidfile $pidfile"; return 0; }

  if ! ps -p "$pid" >/dev/null 2>&1; then
    info "pid $pid already gone"; rm -f "$pidfile"; return 0
  fi
  # PID reuse guard: the live process must still be ours.
  if ! ps -p "$pid" -o args= | grep -Fq -- "$argv_match"; then
    die "pid $pid no longer matches '$argv_match' — refusing to kill (PID reuse)"
  fi

  {
    printf '[%s] DESTRUCTIVE OPERATION\n' "$(ts)"
    printf '  Command:    kill -%s %s\n' "$sig" "$pid"
    printf '  Target:     %s (%s)\n' "$pid" "$argv_match"
    printf '  Authorized: process started by this package (%s)\n' "$pidfile"
    printf '  Reversible: yes — restart via start.sh\n\n'
  } >>"$COMMANDS_LOG"

  info "kill -$sig $pid ($argv_match)"
  kill "-$sig" "$pid"
  rm -f "$pidfile"
}

# --- waiting ---------------------------------------------------------------
# Never `sleep 30 && hope`. Poll for the actual condition with a bounded timeout.

# wait_for_port <host> <port> <timeout-seconds>
wait_for_port() {
  local host="$1" port="$2" timeout="${3:-120}" i=0
  while (( i < timeout )); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then exec 3>&- 2>/dev/null; return 0; fi
    sleep 1; ((i++))
  done
  return 1
}

# wait_for_log <file> <pattern> <timeout-seconds>
# `grep -q` inside a loop must not abort the script when it does not match yet — hence
# the `|| true` discipline throughout this file.
wait_for_log() {
  local file="$1" pattern="$2" timeout="${3:-180}" i=0
  while (( i < timeout )); do
    [[ -f "$file" ]] && grep -Eq -- "$pattern" "$file" 2>/dev/null && return 0
    sleep 1; ((i++))
  done
  return 1
}

# wait_for_http <url> <expected-status> <timeout-seconds>
wait_for_http() {
  local url="$1" want="${2:-200}" timeout="${3:-120}" i=0 got
  while (( i < timeout )); do
    got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    [[ "$got" == "$want" ]] && return 0
    sleep 1; ((i++))
  done
  return 1
}

# count_matches <file> <pattern>  — `grep -c` prints 0 AND exits 1; both need handling.
count_matches() {
  local n
  n="$(grep -Ec -- "$2" "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# --- terminals (spec §7) ---------------------------------------------------
# launch_terminal <label> <command-string>
# Opens a visible terminal per process when a desktop session is available.
# Emulators launched over D-Bus (ptyxis, gnome-terminal) do NOT inherit this shell's
# environment, so the caller must embed every needed variable in the command string.
# Falls back to tmux, then to background+nohup, so the package still runs headless.
launch_terminal() {
  local label="$1" cmd="$2" term
  for term in ptyxis gnome-terminal konsole xfce4-terminal xterm; do
    command -v "$term" >/dev/null 2>&1 || continue
    case "$term" in
      ptyxis)         ptyxis --title "$label" -- bash -lc "$cmd; exec bash" & ;;
      gnome-terminal) gnome-terminal --title="$label" -- bash -lc "$cmd; exec bash" & ;;
      konsole)        konsole -p tabtitle="$label" -e bash -lc "$cmd; exec bash" & ;;
      xfce4-terminal) xfce4-terminal --title="$label" -x bash -lc "$cmd; exec bash" & ;;
      xterm)          xterm -T "$label" -e bash -lc "$cmd; exec bash" & ;;
    esac
    info "[$label] launched in $term"
    return 0
  done
  if command -v tmux >/dev/null 2>&1; then
    tmux new-session -d -s "$label" "bash -lc '$cmd'"
    info "[$label] launched in tmux session '$label'"
    return 0
  fi
  warn "[$label] no terminal emulator — falling back to background execution"
  nohup bash -lc "$cmd" >"$LOG_DIR/$label.log" 2>&1 &
  echo $! >"$PKG_DIR/$label.pid"
}

# --- node table ------------------------------------------------------------
# NODES entries are "name http_port mgmt_port jgroups_port base_dir" (see nodes.env).
node_field() { local name="$1" idx="$2" n; for n in "${NODES[@]}"; do
  set -- $n; [[ "$1" == "$name" ]] && { echo "${!idx}"; return 0; }; done; return 1; }

node_names()   { local n; for n in "${NODES[@]}"; do set -- $n; echo "$1"; done; }
node_http()    { node_field "$1" 2; }
node_mgmt()    { node_field "$1" 3; }
node_jgroups() { node_field "$1" 4; }
node_base()    { echo "$PKG_DIR/$(node_field "$1" 5)"; }
