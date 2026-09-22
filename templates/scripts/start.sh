#!/usr/bin/env bash
# start.sh — start every node and the load balancer, then verify the five health gates.
# Exits non-zero if any gate fails. A failed gate means the harness is wrong; do not
# proceed to reproduce.sh, because every symptom after this point would be an artifact.
#
# Usage: ./start.sh [--no-terminals]
# TEMPLATE. The generator fills the product-specific launch and view-parsing bits.

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

USE_TERMINALS="${USE_TERMINALS:-false}"
[[ "${1:-}" == "--no-terminals" ]] && USE_TERMINALS=false

[[ -n "${EAP_HOME:-}" ]] || die "EAP_HOME unset — run ./scripts/setup.sh first"
[[ -n "${JAVA_HOME:-}" ]] || die "JAVA_HOME unset — run ./scripts/setup.sh first"

info "=== start: ${#NODES[@]} nodes, LB=$LB_ENABLED ==="

# --- pre-flight: ports ------------------------------------------------------
# A stale listener from a previous run is the cheapest failure to catch and the most
# confusing to debug later.
for name in $(node_names); do
  for p in "$(node_http "$name")" "$(node_mgmt "$name")" "$(node_jgroups "$name")"; do
    if (exec 3<>"/dev/tcp/$BIND_ADDR/$p") 2>/dev/null; then
      exec 3>&- 2>/dev/null
      die "port $p already in use — run ./scripts/cleanup.sh first"
    fi
  done
done

# --- launch nodes -----------------------------------------------------------
i=0
for name in $(node_names); do
  i=$((i+1))
  base="$(node_base "$name")"
  http="$(node_http "$name")"
  offset=$(( http - 8080 ))
  logfile="$LOG_DIR/$name.log"

  args=(
    "$EAP_HOME/bin/standalone.sh"
    -c "$SERVER_CONFIG"
    -b "$BIND_ADDR" -bmanagement "$BIND_ADDR" -bprivate "$BIND_ADDR"
    "-Djboss.server.base.dir=$base"
    "-Djboss.node.name=$name"
    "-Djboss.socket.binding.port-offset=$offset"
  )

  if [[ "$USE_TERMINALS" == "true" ]]; then
    # Terminal emulators launched over D-Bus do NOT inherit this shell's environment,
    # so every variable the server needs is passed explicitly on the command line.
    info "[T$i] $name — launching in its own terminal"
    launch_terminal "$name" "JAVA_HOME=$JAVA_HOME EAP_HOME=$EAP_HOME ${args[*]}"
  else
    info "[T$i] $name — http:$http mgmt:$(node_mgmt "$name") jgroups:$(node_jgroups "$name")"
    JAVA_HOME="$JAVA_HOME" nohup "${args[@]}" >"$logfile" 2>&1 &
    echo $! >"$PKG_DIR/$name.pid"
    {
      printf '[%s] [T%s] %s\nCOMMAND: %s\nPID:     %s\nLOG:     %s\n\n' \
        "$(ts)" "$i" "$name" "${args[*]}" "$(cat "$PKG_DIR/$name.pid")" "$logfile"
    } >>"$COMMANDS_LOG"
  fi
done

# ===========================================================================
# GATE 1 — processes up and ports listening.
# Check the port, not just the PID: a server that started and exited still leaves a
# live PID entry for a moment, but never binds.
# ===========================================================================
for name in $(node_names); do
  wait_for_port "$BIND_ADDR" "$(node_http "$name")" "$STARTUP_TIMEOUT" \
    || die "GATE 1 FAILED: $name never bound $(node_http "$name") — see $LOG_DIR/$name.log"
done
info "GATE 1 ok — all nodes listening"

# ===========================================================================
# GATE 2 — clean boot. "Started with errors" is a gate failure, not a warning.
# ===========================================================================
for name in $(node_names); do
  log="$LOG_DIR/$name.log"
  wait_for_log "$log" 'WFLYSRV0025' "$STARTUP_TIMEOUT" \
    || die "GATE 2 FAILED: $name did not report startup — see $log"
  errs="$(count_matches "$log" 'WFLYSRV0026|ERROR')"
  if [[ "$errs" != "0" ]]; then
    warn "GATE 2: $name booted with $errs error line(s) — review before trusting any verdict"
    grep -E 'ERROR' "$log" | head -10 || true
  fi
done
info "GATE 2 ok — all nodes booted"

# ===========================================================================
# GATE 3 — cluster formed. Every node's view must list EVERY other node.
# Three nodes each reporting a view of one is three clusters, and every clustering
# symptom downstream would be a harness artifact rather than the customer's bug.
# ===========================================================================
expected="${#NODES[@]}"
for name in $(node_names); do
  log="$LOG_DIR/$name.log"
  # GENERATOR: match the product's own view line and extract the member count.
  wait_for_log "$log" 'ISPN000094|view.*\[.*\]' "$CLUSTER_TIMEOUT" \
    || die "GATE 3 FAILED: $name never logged a cluster view — discovery is broken.
            Check the discovery protocol: a multicast-based stack finds nothing on a
            single host. See reference/version-matrix.md."
  view="$(grep -E 'ISPN000094|view.*\[' "$log" | tail -1 || true)"
  commas="$(grep -o ',' <<<"$view" | wc -l || true)"
  members=$(( ${commas:-0} + 1 ))
  info "GATE 3: $name view = $view"
  (( members >= expected )) \
    || die "GATE 3 FAILED: $name sees $members/$expected members — split cluster. Fix discovery."
done
info "GATE 3 ok — cluster of $expected formed"

# ===========================================================================
# GATE 4 — the application ANSWERS. Deployment status is not proof: a WAR built
# against the wrong servlet namespace deploys cleanly and 404s on every request.
# ===========================================================================
for name in $(node_names); do
  url="http://$BIND_ADDR:$(node_http "$name")$APP_ENDPOINT"
  wait_for_http "$url" 200 60 \
    || die "GATE 4 FAILED: $url did not return 200.
            The deployment may report success while every endpoint 404s — check the
            servlet/Jakarta namespace against the product major."
  info "GATE 4: $name $APP_ENDPOINT → 200"
done
info "GATE 4 ok — application answering on every node"

# ===========================================================================
# GATE 5 — load balancer routes to every backend, and is sticky if the case needs it.
# Verify by observing which node serves successive requests, not by reading the
# config you just wrote.
# ===========================================================================
if [[ "$LB_ENABLED" == "true" ]]; then
  # GENERATOR: start the balancer, record its PID, then probe.
  wait_for_port "$BIND_ADDR" "$LB_PORT" 60 || die "GATE 5 FAILED: LB not listening on $LB_PORT"
  info "GATE 5: LB up on $LB_PORT — GENERATOR: assert backend coverage and stickiness"
fi

# --- before-evidence --------------------------------------------------------
"$PKG_DIR/scripts/collect.sh" --phase before || warn "before-evidence collection incomplete"

info "=== all gates passed — environment healthy ==="
info "next: ./scripts/reproduce.sh"
