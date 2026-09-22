#!/usr/bin/env bash
# cleanup.sh — stop everything this package started and remove the state it created.
# Never touches the product installation, the case input, or the collected evidence.
#
# Usage: ./cleanup.sh [--purge]
#   (default)  stop processes, leave evidence/, logs/ and node state in place
#   --purge    additionally remove the per-node base dirs and logs/ — evidence/ survives

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

info "=== cleanup (purge=$PURGE) ==="

# --- stop the load balancer -------------------------------------------------
[[ -f "$PKG_DIR/lb.pid" ]] && kill_recorded_pid "$PKG_DIR/lb.pid" "httpd" TERM

# --- stop the nodes ---------------------------------------------------------
# Graceful first, then force. Match the SERVER's argv, not the wrapper script:
# killing standalone.sh leaves the JVM orphaned, still bound to its port and still
# serving requests, which silently poisons the next run.
for name in $(node_names); do
  pidfile="$PKG_DIR/$name.pid"
  [[ -f "$pidfile" ]] || continue
  kill_recorded_pid "$pidfile" "jboss.node.name=$name" TERM || true
done

for name in $(node_names); do
  port="$(node_http "$name")"
  i=0
  while (( i < 30 )); do
    (exec 3<>"/dev/tcp/$BIND_ADDR/$port") 2>/dev/null || break
    exec 3>&- 2>/dev/null; sleep 1; ((i++))
  done
  if (exec 3<>"/dev/tcp/$BIND_ADDR/$port") 2>/dev/null; then
    exec 3>&- 2>/dev/null
    warn "$name still listening on $port after TERM"
    # Escalate only against a process whose argv identifies it as ours. Never a broad
    # pattern: `pkill -f java` takes out the user's IDE and every unrelated JVM.
    pid="$(ps -eo pid,args | grep -F "jboss.node.name=$name" | grep -v grep | awk '{print $1}' | head -1 || true)"
    if [[ -n "$pid" ]]; then
      info "escalating: kill -9 $pid ($name)"
      kill -9 "$pid" || true
    else
      warn "no process matching jboss.node.name=$name — refusing to guess a target"
    fi
  fi
done

# --- container / OpenShift resources ----------------------------------------
# Only resources labelled as created by this run, in a namespace this run created or
# the user named. Never --all, never a discovered namespace.
if [[ -n "${REPRO_NAMESPACE:-}" ]] && command -v oc >/dev/null 2>&1; then
  info "oc context: $(oc whoami 2>/dev/null || echo unknown) / $REPRO_NAMESPACE"
  run_cmd CLEANUP oc delete all -l "repro-case=${CASE_ID:-unknown}" -n "$REPRO_NAMESPACE" || true
fi
if [[ -n "${REPRO_CONTAINERS:-}" ]]; then
  for c in $REPRO_CONTAINERS; do
    run_cmd CLEANUP podman rm -f "$c" || true
  done
fi

# --- state ------------------------------------------------------------------
if [[ "$PURGE" == "true" ]]; then
  for name in $(node_names); do
    base="$(node_base "$name")"
    assert_in_pkg "$base"                      # refuses on an unset/escaping path
    [[ -d "$base" ]] && { info "removing $base"; rm -rf "${base:?}"; }
  done
  assert_in_pkg "$LOG_DIR"
  rm -rf "${LOG_DIR:?}"/*
  rm -f "$PKG_DIR"/output/*.body "$PKG_DIR"/output/*.headers "$PKG_DIR"/output/cookies.txt
  info "purged node state and logs — evidence/, issue.txt and the reports are untouched"
fi

rm -f "$PKG_DIR"/*.pid
info "=== cleanup complete ==="
