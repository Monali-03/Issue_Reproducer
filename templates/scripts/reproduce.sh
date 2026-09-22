#!/usr/bin/env bash
# reproduce.sh — establish the baseline, then run the customer's steps exactly.
# Prints a three-valued verdict and, with --repeat, a hit rate.
#
# Usage: ./reproduce.sh [--repeat N]
# TEMPLATE. The generator fills BASELINE, INJECT and MEASURE for the specific case.

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

[[ "${1:-}" == "--repeat" ]] && REPEAT="${2:-1}"

PASS=0      # behaved correctly — issue NOT reproduced this round
FAIL=0      # customer's symptom observed — issue REPRODUCED this round
INCONC=0    # neither: auth error, node would not die, request never landed

COOKIES="$PKG_DIR/output/cookies.txt"
LB_URL="http://$BIND_ADDR:$LB_PORT$APP_ENDPOINT"

# ---------------------------------------------------------------------------
# Record a full HTTP exchange as evidence. A transcript without its request line
# is not evidence, and "which node served it" is the entire content of a failover
# claim — so capture the backend marker too.
# ---------------------------------------------------------------------------
http_get() {
  local url="$1" tag="$2" out="$PKG_DIR/output/$tag"
  curl -sS -D "$out.headers" -b "$COOKIES" -c "$COOKIES" \
       -o "$out.body" -w '%{http_code}' --max-time 10 "$url" 2>"$out.err" || echo "000"
}

run_round() {
  local round="$1"
  info "--- round $round/$REPEAT ---"

  # =========================================================================
  # BASELINE — prove the feature works BEFORE breaking anything.
  # A failing baseline is always a harness fault. Without a passing baseline
  # there is no verdict in either direction, so this is inconclusive, never
  # a reproduction.
  # =========================================================================
  rm -f "$COOKIES"
  local code served_by
  code="$(http_get "$LB_URL" "r${round}-baseline-1")"
  if [[ "$code" != "200" ]]; then
    warn "baseline request returned $code — INCONCLUSIVE (harness, not the product)"
    INCONC=$((INCONC+1)); return
  fi

  # GENERATOR: assert the feature works across nodes — session counter increments and
  # sticks, cache entry reads back from a second server, handshake completes.
  code="$(http_get "$LB_URL" "r${round}-baseline-2")"
  [[ "$code" == "200" ]] || { warn "baseline second request $code — INCONCLUSIVE"; INCONC=$((INCONC+1)); return; }

  served_by="$(grep -i '^x-served-by\|JSESSIONID' "$PKG_DIR/output/r${round}-baseline-2.headers" | head -1 || true)"
  info "baseline ok — served by: ${served_by:-unknown}"
  cp "$PKG_DIR/output/r${round}-baseline-2.headers" "$EVIDENCE_DIR/before/baseline-r${round}.txt"

  # =========================================================================
  # INJECT — the customer's failure, modelled the way the customer described it.
  #
  #   "node crashed"        → kill -9
  #   "node was restarted"  → graceful shutdown, then start
  #   "the network dropped" → NEITHER. Killing a process sends FIN/RST and the peer
  #                           detects it instantly, which is the opposite of a
  #                           partition. Simulate silence with silence: stall a
  #                           proxy that holds the sockets open.
  #
  # Then CONFIRM the injection landed before measuring its consequences.
  # =========================================================================
  local target; target="$(node_names | head -1)"
  info "injecting failure on $target"
  echo "[$(ts)] INJECT on $target" >>"$EVIDENCE_DIR/during/timeline.txt"

  kill_recorded_pid "$PKG_DIR/$target.pid" "jboss.node.name=$target" KILL

  # Confirm: the port must actually be closed. A wrapper-only kill orphans the JVM,
  # which keeps serving, so the failover never happens and the verdict is garbage.
  local i=0
  while (( i < 30 )); do
    (exec 3<>"/dev/tcp/$BIND_ADDR/$(node_http "$target")") 2>/dev/null || break
    exec 3>&- 2>/dev/null; sleep 1; ((i++))
  done
  if (exec 3<>"/dev/tcp/$BIND_ADDR/$(node_http "$target")") 2>/dev/null; then
    exec 3>&- 2>/dev/null
    warn "$target still listening after kill — injection did not land. INCONCLUSIVE"
    INCONC=$((INCONC+1)); return
  fi
  info "$target is down and its port is closed"

  # Give the surviving members time to converge on the new view.
  sleep 5

  # =========================================================================
  # MEASURE — the pre-declared success criterion from reproduction-plan.md.
  # Deciding here what would have counted is how a harness failure becomes a
  # reported bug. The criterion was written before the run; apply it literally.
  # =========================================================================
  code="$(http_get "$LB_URL" "r${round}-after")"
  cp "$PKG_DIR/output/r${round}-after.headers" "$EVIDENCE_DIR/after/response-r${round}.txt"

  if [[ "$code" == "000" || "$code" == "503" ]]; then
    warn "post-failover request returned $code — LB had no healthy backend. INCONCLUSIVE"
    INCONC=$((INCONC+1)); return
  fi

  # GENERATOR: replace with the case's literal criterion. Example for session failover:
  #   reproduced  = counter reset to 0, or a new JSESSIONID issued
  #   not reprod. = counter continued from its pre-failover value on the same session
  if grep -q 'GENERATOR_SYMPTOM_PATTERN' "$PKG_DIR/output/r${round}-after.body" 2>/dev/null; then
    info "round $round: SYMPTOM OBSERVED — issue reproduced"
    FAIL=$((FAIL+1))
  else
    info "round $round: behaved correctly — issue not reproduced"
    PASS=$((PASS+1))
  fi

  # Restart the injected node so the next round starts from a healthy cluster.
  if (( REPEAT > 1 )); then
    info "restoring $target for the next round"
    # GENERATOR: relaunch $target exactly as start.sh does, and re-verify the gates.
  fi
}

info "=== reproduce: $REPEAT round(s) ==="
for r in $(seq 1 "$REPEAT"); do run_round "$r"; done

# ---------------------------------------------------------------------------
# Verdict. Inconclusive rounds count as NEITHER outcome — folding them into the
# failure bucket is the most common way a tool reports a bug that is not there.
# ---------------------------------------------------------------------------
TOTAL=$(( PASS + FAIL + INCONC ))
{
  printf '\n=== RESULT ===\n'
  printf 'rounds:        %s\n' "$TOTAL"
  printf 'reproduced:    %s\n' "$FAIL"
  printf 'not reproduced:%s\n' "$PASS"
  printf 'inconclusive:  %s\n' "$INCONC"
} | tee -a "$REPRO_LOG"

if (( FAIL > 0 )); then
  info "VERDICT: ISSUE REPRODUCED — hit rate $FAIL/$TOTAL ($INCONC inconclusive)"
  exit 0
elif (( PASS > 0 && INCONC == 0 )); then
  info "VERDICT: ISSUE NOT REPRODUCED — $PASS/$TOTAL clean runs"
  exit 0
else
  info "VERDICT: INCONCLUSIVE — the harness never produced a measurable outcome"
  exit 2
fi
