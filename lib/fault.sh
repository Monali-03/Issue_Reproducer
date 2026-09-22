#!/usr/bin/env bash
# fault.sh — the injection library.
#
# The counterpart to probe.sh: probes observe, faults change something. Between them they
# are the two halves every existing scenario path already has, written once instead of once
# per scenario.
#
# Contract for every fault_* function:
#   * returns 0 when the fault was applied, non-zero when it was NOT
#   * on failure sets FAULT_FAILED_REASON to a sentence naming what did not happen
#
# That return value matters more than it looks. A fault that silently did not happen turns
# an unchanged measurement into "NOT REPRODUCED" — the harness reporting the product healthy
# because the harness never touched it. Rule 3: the engine treats a failed injection as
# INCONCLUSIVE, never as a negative result.

FAULT_FAILED_REASON=""
FAULT_LOG=""          # human-readable record of everything injected, for the report

fault_note() {
  FAULT_LOG+="${FAULT_LOG:+$'\n'}$1"
  printf '[%s] FAULT %s\n' "$(ts)" "$1" >>"$COMMANDS_LOG"
}

fault_evidence() {
  local name; name="$(slugify "$1")"
  mkdir -p "$PKG/evidence/during"
  printf '%s/fault-%s.txt' "$PKG/evidence/during" "$name"
}

# --- no-op ---------------------------------------------------------------------
# Not a placeholder. Plenty of cases have no fault to inject because the fault is already
# in the customer's configuration — a bad keystore, a javax WAR, owners=1. For those the
# measurement is just "start it as configured and look", and the honest way to express that
# is a plan with no injection rather than a fabricated one.
fault_none() {
  fault_note "none — the configuration under test is itself the fault; nothing was injected"
  return 0
}

# --- node loss -------------------------------------------------------------------
# fault_kill_node <index>
fault_kill_node() {
  local idx="${1:-0}"
  if declare -F eap_kill_node >/dev/null 2>&1; then
    eap_kill_node "$idx"
    fault_note "killed EAP node index $idx (${EAP_NODES[$idx]})"
    return 0
  fi
  if declare -F dg_kill_node >/dev/null 2>&1; then
    dg_kill_node "$idx"
    fault_note "killed Data Grid node index $idx (${DG_NODES[$idx]})"
    return 0
  fi
  FAULT_FAILED_REASON="kill_node was requested but no driver is loaded that knows how to stop a node"
  return 1
}

# --- load ---------------------------------------------------------------------------
# fault_load <url> [concurrency] [requests-per-worker] [curl-args...]
#
# The generic way to make a resource-exhaustion case happen: pool starvation, thread
# exhaustion, GC pressure, accept-queue overflow. It reports how many requests actually
# completed, because "the load never ran" and "the load ran and nothing broke" are
# different findings and only one of them is a negative result.
fault_load() {
  local url="$1" conc="${2:-20}" reqs="${3:-50}"; shift 3 2>/dev/null || shift $#
  local out; out="$(fault_evidence "load")"
  assert_in_pkg "$out.codes"; : >"$out.codes"
  step "Injecting load — $conc concurrent workers x $reqs requests against $url"

  local -a pids=()
  local w
  for (( w=0; w<conc; w++ )); do
    (
      # No `local` here: a subshell is not a function body and the builtin would abort it.
      for (( i=0; i<reqs; i++ )); do
        # curl already prints 000 via -w when it never got a response, so an `|| echo 000`
        # here concatenates onto that and yields "000000", which matches no status pattern
        # and silently turns a dead endpoint into an unclassifiable one.
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" "$url" 2>/dev/null || true)"
        printf '%s\n' "${code:-000}"
      done
    ) >>"$out.codes" 2>/dev/null &
    pids+=($!)
  done

  # A bare `wait $pid` aborts the script when the worker exited non-zero, and a worker
  # hitting a hung server is expected to.
  local p rc
  for p in "${pids[@]}"; do rc=0; wait "$p" || rc=$?; done

  local total ok_n fail_n none_n
  total="$(wc -l <"$out.codes" 2>/dev/null || echo 0)"
  ok_n="$(grep -cE '^2[0-9][0-9]$' "$out.codes" 2>/dev/null || true)"
  fail_n="$(grep -cE '^5[0-9][0-9]$' "$out.codes" 2>/dev/null || true)"
  none_n="$(grep -cE '^000$' "$out.codes" 2>/dev/null || true)"
  {
    printf 'url          : %s\nworkers      : %s\nper worker   : %s\n' "$url" "$conc" "$reqs"
    printf 'attempted    : %s\n2xx          : %s\n5xx          : %s\nno response  : %s\n' \
           "${total:-0}" "${ok_n:-0}" "${fail_n:-0}" "${none_n:-0}"
    printf -- '--- status code tally ---\n'
    sort "$out.codes" 2>/dev/null | uniq -c | sort -rn || true
  } >"$out"

  # Two different nothings, and only the second is a result. Zero attempts means the
  # generator did not run; every attempt returning 000 means it ran but never reached the
  # server, so the server was not loaded and a later "nothing broke" would be about the
  # harness. A 5xx under load, by contrast, is the product answering.
  if (( ${total:-0} == 0 )); then
    FAULT_FAILED_REASON="the load generator attempted zero requests against $url"
    return 1
  fi
  if (( ${none_n:-0} == ${total:-0} )); then
    FAULT_FAILED_REASON="all ${total} load requests against $url got no response at all (connection refused or timed out), so the server was never actually put under load"
    return 1
  fi
  fault_note "load: $conc x $reqs against $url — ${total:-0} attempted, ${ok_n:-0} 2xx, ${fail_n:-0} 5xx, ${none_n:-0} no response"
  return 0
}

# --- redeploy ----------------------------------------------------------------------
# fault_redeploy [cycles] [node-index]
#
# Classloader-leak and metaspace cases turn on the redeploy cycle itself. Both EAP drivers
# deploy by dropping the archive in the scanner directory, so undeploy/redeploy is the same
# operation in reverse and needs no CLI.
fault_redeploy() {
  local cycles="${1:-10}" idx="${2:-0}"
  if [[ -z "${APP_FILE:-}" || ! -f "${APP_FILE:-}" ]]; then
    FAULT_FAILED_REASON="redeploy was requested but no deployable artifact is known (APP_FILE unset)"
    return 1
  fi
  if ! declare -p EAP_NODES >/dev/null 2>&1; then
    FAULT_FAILED_REASON="redeploy is only implemented for the EAP drivers"
    return 1
  fi
  local node="${EAP_NODES[$idx]}"
  local dir="$PKG/nodes/$node/deployments"
  local war; war="$(basename "$APP_FILE")"
  local out; out="$(fault_evidence "redeploy")"
  step "Injecting $cycles redeploy cycles of $war on $node"

  local c done_n=0
  assert_in_pkg "$dir/$war"
  : >"$out"
  for (( c=1; c<=cycles; c++ )); do
    rm -f "$dir/$war.deployed" "$dir/$war.failed" "$dir/$war"
    if ! wait_for_file_gone "$dir/$war.deployed" 60; then
      printf 'cycle %s: undeploy marker never cleared\n' "$c" >>"$out"
      break
    fi
    cp "$APP_FILE" "$dir/"
    if ! wait_for_file "$dir/$war.deployed" 90; then
      printf 'cycle %s: redeploy marker never appeared\n' "$c" >>"$out"
      break
    fi
    done_n=$c
    printf 'cycle %s: redeployed\n' "$c" >>"$out"
  done

  if (( done_n == 0 )); then
    FAULT_FAILED_REASON="not one redeploy cycle completed on $node — see $out"
    return 1
  fi
  if (( done_n < cycles )); then
    fault_note "redeploy: only $done_n of $cycles cycles completed on $node (see $out)"
  else
    fault_note "redeploy: $done_n cycles of $war on $node"
  fi
  return 0
}

wait_for_file() {
  local f="$1" t="${2:-60}" i=0
  while (( i < t )); do [[ -f "$f" ]] && return 0; sleep 1; i=$((i+1)); done
  return 1
}
wait_for_file_gone() {
  local f="$1" t="${2:-60}" i=0
  while (( i < t )); do [[ -f "$f" ]] || return 0; sleep 1; i=$((i+1)); done
  return 1
}

# --- time --------------------------------------------------------------------------
# fault_wait <seconds> — for cases whose trigger is a timer: idle-timeout reaping, a
# scheduled job, a leak that only shows after the first full GC. Bounded and recorded, so
# it is a declared part of the plan rather than a `sleep` someone added to make a test pass.
fault_wait() {
  local secs="${1:-60}"
  (( secs > 1800 )) && secs=1800
  step "Waiting ${secs}s for the time-dependent condition to develop"
  sleep "$secs"
  fault_note "waited ${secs}s (time-triggered case)"
  return 0
}

# --- runtime change ------------------------------------------------------------------
# fault_cli <jboss-cli command> [node-index]
# Applies one runtime change through the management API — the general form of "turn this
# setting into the customer's setting while the server is up".
fault_cli() {
  local cmd="$1" idx="${2:-0}" out raw
  if ! declare -p EAP_MGMT >/dev/null 2>&1 || ! declare -F eap_cli >/dev/null 2>&1; then
    FAULT_FAILED_REASON="a CLI fault was requested outside an EAP run"
    return 1
  fi
  out="$(fault_evidence "cli")"
  raw="$(eap_cli "${EAP_MGMT[$idx]}" "$cmd" || true)"
  printf 'command: %s\n--- result ---\n%s\n' "$cmd" "$raw" >>"$out"
  if ! grep -q '"outcome" => "success"' <<<"$raw"; then
    FAULT_FAILED_REASON="the management operation was rejected: $cmd"
    return 1
  fi
  fault_note "applied via CLI on ${EAP_NODES[$idx]}: $cmd"
  return 0
}

# --- dispatcher ------------------------------------------------------------------------
fault_inject() {
  local kind="$1"; shift
  case "$kind" in
    none)      fault_none            ;;
    kill_node) fault_kill_node "$@"  ;;
    load)      fault_load      "$@"  ;;
    redeploy)  fault_redeploy  "$@"  ;;
    wait)      fault_wait      "$@"  ;;
    cli)       fault_cli       "$@"  ;;
    *) FAULT_FAILED_REASON="unknown fault kind '$kind' — this build cannot inject it"
       return 1 ;;
  esac
}

FAULT_KINDS="none kill_node load redeploy wait cli"
export FAULT_KINDS
