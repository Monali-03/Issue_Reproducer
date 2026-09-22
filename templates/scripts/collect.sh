#!/usr/bin/env bash
# collect.sh — capture evidence for one phase into evidence/<phase>/.
# Copies, never moves. Never truncates a live log.
#
# Usage: ./collect.sh [--phase before|during|after]   (default: after)

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

PHASE="after"
[[ "${1:-}" == "--phase" ]] && PHASE="${2:-after}"
DEST="$EVIDENCE_DIR/$PHASE"
mkdir -p "$DEST"

info "=== collect: phase=$PHASE → $DEST ==="
echo "collected: $(ts)" >"$DEST/_collected-at.txt"

# --- process and port state -------------------------------------------------
{ ps -ef | grep -E 'standalone|jboss|infinispan|httpd' | grep -v grep || true; } >"$DEST/processes.txt"
{ ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || true; }          >"$DEST/ports.txt"
{ ip -br addr; echo; ip -br link; }                                        >"$DEST/network.txt" 2>&1

# --- JVM state, per recorded PID --------------------------------------------
# Only PIDs this package started — never a PID discovered by scanning.
for pidfile in "$PKG_DIR"/*.pid; do
  [[ -f "$pidfile" ]] || continue
  name="$(basename "$pidfile" .pid)"
  pid="$(cat "$pidfile")"
  ps -p "$pid" >/dev/null 2>&1 || { echo "pid $pid not running" >"$DEST/$name-jvm.txt"; continue; }

  JCMD="${JAVA_HOME:+$JAVA_HOME/bin/}jcmd"
  {
    echo "=== VM.command_line ===";     "$JCMD" "$pid" VM.command_line      2>&1 || true
    echo "=== VM.flags ===";            "$JCMD" "$pid" VM.flags             2>&1 || true
    echo "=== VM.system_properties ==="; "$JCMD" "$pid" VM.system_properties 2>&1 || true
    echo "=== GC.heap_info ===";        "$JCMD" "$pid" GC.heap_info         2>&1 || true
  } >"$DEST/$name-jvm.txt"

  # For a hang or a deadlock, one dump shows threads at an instant; three show whether
  # they are stuck or merely busy — which is the actual question being asked.
  for n in 1 2 3; do
    "$JCMD" "$pid" Thread.print >"$DEST/$name-threaddump-$n.txt" 2>&1 || true
    (( n < 3 )) && sleep 10
  done
done

# --- logs -------------------------------------------------------------------
mkdir -p "$DEST/logs"
for name in $(node_names); do
  base="$(node_base "$name")"
  for f in "$base/log/server.log" "$base/log/boot.log" "$LOG_DIR/$name.log"; do
    [[ -f "$f" ]] && cp "$f" "$DEST/logs/$name-$(basename "$f")"
  done
  for g in "$base"/log/gc*.log*; do [[ -f "$g" ]] && cp "$g" "$DEST/logs/$name-$(basename "$g")"; done
done
for f in "$LOG_DIR"/lb*.log "$LOG_DIR"/*access*.log "$LOG_DIR"/*error*.log; do
  [[ -f "$f" ]] && cp "$f" "$DEST/logs/"
done

# --- cluster state ----------------------------------------------------------
# Pull the view from the management API AND from each node's own log. They can
# disagree, and the disagreement is itself the finding.
for name in $(node_names); do
  mgmt="$(node_mgmt "$name")"
  if [[ -x "${EAP_HOME:-}/bin/jboss-cli.sh" ]]; then
    "$EAP_HOME/bin/jboss-cli.sh" -c --controller="$BIND_ADDR:$mgmt" \
      --command='/subsystem=jgroups/channel=ee:read-attribute(name=view)' \
      >"$DEST/$name-cluster-view.txt" 2>&1 || true
    "$EAP_HOME/bin/jboss-cli.sh" -c --controller="$BIND_ADDR:$mgmt" \
      --command='/deployment=*:read-attribute(name=status)' \
      >"$DEST/$name-deployments.txt" 2>&1 || true
  fi
  grep -E 'ISPN000094|ISPN000439|view.*\[' "$LOG_DIR/$name.log" 2>/dev/null \
    >"$DEST/$name-view-history.txt" || true
done

# --- configuration snapshot -------------------------------------------------
mkdir -p "$DEST/config"
for name in $(node_names); do
  base="$(node_base "$name")"
  [[ -f "$base/configuration/$SERVER_CONFIG" ]] \
    && cp "$base/configuration/$SERVER_CONFIG" "$DEST/config/$name-$SERVER_CONFIG"
done

# --- heap dumps: record, never parse ----------------------------------------
for h in "$PKG_DIR"/**/*.hprof; do
  [[ -f "$h" ]] || continue
  printf '%s  %s bytes  %s\n' "$h" "$(stat -c%s "$h")" "$(stat -c%y "$h")" >>"$DEST/heapdumps.txt"
done

# --- redaction --------------------------------------------------------------
# Strip credentials. Keep hostnames, IPs and ports — topology is the point.
find "$DEST" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.xml' \) -print0 \
  | xargs -0 -r sed -i -E \
      -e 's/(password|passwd|secret|token|apikey|api_key)([">=: ]+)[^"<[:space:]]+/\1\2***REDACTED***/Ig' \
      -e 's/(Authorization: *(Basic|Bearer) *)[A-Za-z0-9._~+\/=-]+/\1***REDACTED***/Ig'

# --- manifest ---------------------------------------------------------------
{
  printf '%-52s %10s  %-64s\n' FILE BYTES SHA256
  find "$DEST" -type f ! -name MANIFEST.txt | sort | while read -r f; do
    printf '%-52s %10s  %s\n' "${f#"$DEST"/}" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
  done
} >"$DEST/MANIFEST.txt"

info "=== collect done: $(find "$DEST" -type f | wc -l) files in $DEST ==="
