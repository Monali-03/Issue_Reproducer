#!/usr/bin/env bash
# plan.sh — turn a case into a measurement plan.
#
# Two sources, in this order of authority:
#
#   1. input/plan.env   an explicit plan. Whoever writes it — an engineer or a model — is
#                       stating what to measure, and rule 5 says a stated thing is used as
#                       stated. If it exists, nothing is derived.
#   2. derivation       built from what the case actually says: the error codes it quotes,
#                       the HTTP status it quotes, whether its steps kill a node or apply
#                       load. Everything here is INFERRED and labelled as such.
#
# Derivation is deliberately shallow. It reads what the customer wrote down and turns it
# into an observation; it does not decide what the customer *meant*. A case whose symptom is
# not stated in a measurable form produces no plan, and no plan means the caller falls back
# to the log-signature reading rather than this file inventing a criterion.

# --- explicit plan --------------------------------------------------------------------
plan_load_file() {
  local f="$WS_DIR/input/plan.env"
  [[ -f "$f" ]] || return 1
  step "Measurement plan supplied: input/plan.env"
  # Sourced, not evaluated from a capture: `eval "$(cmd)"` does not propagate cmd's failure,
  # and a plan that half-loaded is worse than none.
  # shellcheck disable=SC1090
  source "$f"
  cp "$f" "$PKG/config/plan.env"
  if plan_is_empty; then
    blocked "input/plan.env loaded but declared no probes or no criterion.
       A plan needs at least one plan_probe and one plan_criterion.
       See reference/measurement-plans.md for the vocabulary."
  fi
  plan_source "input/plan.env (stated, not derived)"
  ok "plan loaded: ${#PLAN_PROBES[@]} probe(s), ${#PLAN_FAULTS[@]} fault(s), ${#PLAN_CRITERIA[@]} criterion/criteria"
  return 0
}

# --- what the case states ---------------------------------------------------------------

# Codes a healthy server logs anyway, so their presence is evidence that the server ran and
# nothing more. A case quotes them because they are the line the customer was looking at,
# not because they are the fault:
#
#   WFLYSRV0010  "Deployed"          — the javax-on-EAP-8 trap in one line. A WAR that 404s
#                                      on every path still logs it. Gate 4 exists for this.
#   WFLYCLJG0033 channel local addr  — EAP 8 logs it once at connect, while the node is
#                                      still alone. A cluster-of-one case quoting it would
#                                      be "reproduced" by a perfectly healthy three-node run.
#   ISPN000094   "Received new cluster view" — every healthy cluster logs it, repeatedly.
#
# They stay as probes, because the count is worth having in the package. They are not
# criteria, because counting them decides nothing. What decides those cases is the view
# size or the endpoint response, which is what cluster_view and http_status measure.
PLAN_BENIGN_CODES='^(WFLYSRV0010|WFLYSRV0025|WFLYSRV0026|WFLYSRV0049|WFLYUT0021|WFLYCLJG0033|ISPN000094|ISPN000078|ISPN000079|ISPN000128|ISPN100000|ISPN100002)$'

# Error codes and exception classes the customer quoted. Taken from the case, never invented.
plan_case_codes() {
  grep -hoE '(WFLY[A-Z]*[0-9]{4,}|ISPN[0-9]{6}|IJ[0-9]{6}|JBWEB[0-9]+|JBAS[0-9]+|DGS[0-9]+|java\.[a-zA-Z.]+(Exception|Error)|javax\.[a-zA-Z.]+(Exception|Error))' \
       "$PKG/issue.txt" 2>/dev/null | sort -u || true
}

# An HTTP status the customer quoted as the symptom. Only 4xx/5xx: a 200 in a case is
# describing the expected behaviour, not the fault.
#
# The bare-number form is not enough. "Roughly 400 concurrent users at peak" is a load
# figure, and reading it as an expected HTTP 400 builds a criterion the case never stated —
# which is the exact failure mode rule 2 exists to prevent. The number has to appear in an
# HTTP context to count.
plan_case_http_status() {
  grep -hoiE '(HTTP/[0-9.]+[[:space:]]+[45][0-9][0-9]|HTTP[[:space:]]+(status[[:space:]]+)?[45][0-9][0-9]|status[[:space:]]+(code[[:space:]]+)?[45][0-9][0-9]|(returns?|responds?[[:space:]]+with|answering|getting|receive[sd]?)[[:space:]]+(an?[[:space:]]+)?[45][0-9][0-9]|[45][0-9][0-9][[:space:]]+(Not Found|Internal Server Error|Service Unavailable|Forbidden|Unauthorized|Bad Request|Bad Gateway|Gateway Time-?out))' \
       "$PKG/issue.txt" 2>/dev/null \
    | grep -oE '[45][0-9][0-9]' | sort -u | head -2 || true
}

# Does the case say the customer kills, stops or restarts a node?
plan_case_has_node_loss() {
  grep -qiE 'kill -9|kill one|kill a node|node is killed|stop(ped)? (one|a) node|shut(down| down) (one|a)|restart (one|a) (node|server)|node (crash|fail)|failover' \
       "$PKG/issue.txt" 2>/dev/null
}
plan_case_has_load() {
  grep -qiE 'under load|concurrent|load test|[0-9]+ (concurrent )?(users|threads|requests)|peak (load|traffic)|steady load|throughput' \
       "$PKG/issue.txt" 2>/dev/null
}
plan_case_has_redeploy() {
  grep -qiE 'redeploy|hot deploy|re-deploy|undeploy' "$PKG/issue.txt" 2>/dev/null
}

# --- derivation -------------------------------------------------------------------------

plan_derive() {
  step "No plan supplied — deriving one from what the case states"
  local codes code status n=0 fault_kind="none"
  local -a notes=()

  # --- the fault, from the customer's own reproduction steps ----------------------------
  if plan_case_has_node_loss && (( NODE_COUNT >= 2 )); then
    fault_kind="kill_node"
    plan_fault kill_node 0
    notes+=("fault: kill_node 0 — INFERRED from the case's own steps, which lose a node")
  elif plan_case_has_redeploy; then
    fault_kind="redeploy"
    plan_fault redeploy 10
    notes+=("fault: 10 redeploy cycles — INFERRED from the case, which turns on redeployment")
  elif plan_case_has_load && [[ -n "${APP_CONTEXT:-}" ]] && declare -p EAP_HTTP >/dev/null 2>&1; then
    fault_kind="load"
    plan_fault load "http://$WS_BIND:${EAP_HTTP[0]}/$APP_CONTEXT/info" 20 50
    notes+=("fault: 20x50 requests — INFERRED from the case, which reports the symptom under load")
  else
    notes+=("fault: none — the case names no injectable step, so the configuration under test is the only variable")
  fi

  # --- probe 1: the customer's error signature ------------------------------------------
  codes="$(plan_case_codes)"
  local benign=0
  for code in $codes; do
    if (( n + benign >= 6 )); then break; fi
    plan_probe "sig-$(slugify "$code")" log_count "$code"
    if grep -qE "$PLAN_BENIGN_CODES" <<<"$code"; then
      benign=$((benign+1)); continue
    fi
    # One group for all of them: the case quotes several symptoms of one failure, not a
    # promise that every one will be logged again.
    if [[ "$fault_kind" == "none" ]]; then
      plan_criterion "sig-$(slugify "$code")" gt 0 error-signature
    else
      # `increased` takes no value, but the group is the 4th argument — the empty string
      # is load-bearing.
      plan_criterion "sig-$(slugify "$code")" increased "" error-signature
    fi
    n=$((n+1))
  done
  if (( n > 0 )); then
    notes+=("signature probes: $n code(s) quoted in the case, any one of which appearing in this run's own server logs satisfies that group")
  fi
  if (( benign > 0 )); then
    notes+=("$benign code(s) the case quotes are logged by a healthy server too (WFLYSRV0010, WFLYCLJG0033, ISPN000094 and the like) — counted and recorded, but NOT used as a criterion, because their presence would be satisfied by a working system")
  fi

  # --- probe 2: does the thing still answer ----------------------------------------------
  if declare -p EAP_HTTP >/dev/null 2>&1 && [[ -n "${APP_CONTEXT:-}" ]]; then
    local idx=0 url
    # After a node loss the question is about the survivor, not the corpse.
    if [[ "$fault_kind" == "kill_node" ]] && (( ${#EAP_HTTP[@]} > 1 )); then idx=1; fi
    url="http://$WS_BIND:${EAP_HTTP[$idx]}/$APP_CONTEXT/info"
    plan_probe app-status http_status "$url"
    # A case that says "401/403" is describing one rejection two ways, so the statuses are
    # OR'd rather than demanded together.
    status="$(plan_case_http_status)"
    if [[ -n "$status" ]]; then
      local st
      for st in $status; do plan_criterion app-status eq "$st" http-status; done
      notes+=("endpoint criterion: HTTP $(tr '\n' '/' <<<"$status" | sed 's|/$||') — stated in the case")
    fi
    # A survivor test is only meaningful if the endpoint worked before the fault.
    if [[ "$fault_kind" == "kill_node" ]]; then
      plan_baseline_require app-status eq 200 \
        "The application never served a 200 before the node was killed, so nothing after it can be attributed to the node loss."
    fi
  fi

  # --- probe 3: cluster membership, when there is a cluster --------------------------------
  if (( NODE_COUNT >= 2 )); then
    plan_probe cluster-view cluster_view 0
    if [[ "$fault_kind" == "kill_node" ]]; then
      # Not a criterion: a shrinking view after a kill is the injection working, not the
      # symptom. It is recorded so the reader can see the fault landed.
      notes+=("cluster-view is observed, not judged — a smaller view after a kill is the fault, not the finding")
    fi
  fi

  # --- product-specific additions ----------------------------------------------------------
  plan_derive_datagrid
  plan_derive_jvm

  if plan_is_empty; then
    info "nothing in the case is measurable as a before/after observation"
    return 1
  fi

  plan_symptom "$(plan_symptom_sentence)"
  plan_source "INFERRED from case.txt — $(printf '%s | ' "${notes[@]}" | sed 's/ | $//')"
  ok "derived plan: ${#PLAN_PROBES[@]} probe(s), ${#PLAN_FAULTS[@]} fault(s), ${#PLAN_CRITERIA[@]} criterion/criteria"
  return 0
}

# Data Grid: the cache endpoint is the thing that either answers or does not, and it needs
# digest auth. Without the credentials the probe would read 401 as a product symptom.
plan_derive_datagrid() {
  declare -p DG_PORTS >/dev/null 2>&1 || return 0
  [[ -n "${CACHE_NAME:-}" && -n "${DG_USER:-}" ]] || return 0
  local idx=0 status
  if (( ${#DG_PORTS[@]} > 1 )); then idx=1; fi
  plan_probe cache-endpoint http_status \
    "http://$WS_BIND:${DG_PORTS[$idx]}/rest/v2/caches/$CACHE_NAME" \
    --digest -u "$DG_USER:$DG_PASS"
  # Data Grid cases are usually stated as an HTTP code — 404 for a missing entry, 403 for
  # the auth cases — and without this the plan would have an endpoint probe and nothing to
  # compare it against, which is a reading rather than a measurement.
  status="$(plan_case_http_status)"
  if [[ -n "$status" ]]; then
    local st
    for st in $status; do plan_criterion cache-endpoint eq "$st" http-status; done
  fi
  return 0
}

# JVM: sample the live process only if there still is one. The jvm driver waits for the
# workload to exit before it decides a verdict, so on that path these probes would resolve
# to nothing and contribute UNKNOWN — an INCONCLUSIVE manufactured by the harness's own
# ordering rather than by the product. The GC log and workload stdout both land in
# $PKG/logs/, so the signature probes still have something to read.
plan_derive_jvm() {
  [[ "${WS_NAME:-}" == "jvm" ]] || return 0
  [[ -n "${JVM_PID:-}" ]] && ps -p "$JVM_PID" >/dev/null 2>&1 || return 0
  plan_probe deadlocks thread_deadlock "$JVM_PID"
  plan_probe heap-after-gc heap_used_after_gc "$JVM_PID"
  return 0
}

# One sentence quoting the customer, for the plan header. Taken from the case's own
# "Actual behavior" section — not paraphrased, because a paraphrase is a guess.
plan_symptom_sentence() {
  local s
  s="$(sed -n '/^##[[:space:]]*Actual behavior/I,/^##/p' "$PKG/issue.txt" 2>/dev/null \
       | grep -vE '^##' | grep -vE '^[[:space:]]*$' | head -2 | tr '\n' ' ' || true)"
  s="$(sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$s")"
  if [[ -z "$s" ]]; then printf 'NOT PROVIDED (the case states no "Actual behavior")'
  else printf '%s' "$s"; fi
}

# --- entry point ----------------------------------------------------------------------------
# build_plan — returns 0 when a usable plan exists, 1 when there is nothing to measure.
build_plan() {
  plan_reset
  if plan_load_file; then return 0; fi
  plan_derive
}
