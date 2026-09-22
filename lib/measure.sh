#!/usr/bin/env bash
# measure.sh — the generic measurement engine.
#
# Every hand-written scenario path in this repo is the same five steps with different nouns:
#
#     observe  ->  assert the harness is sane  ->  inject  ->  observe again  ->  decide
#
# What made each one need its own function is that it hardcoded *what* to observe and *what
# counts as the symptom*. Those two are now data — a plan — so a case nobody anticipated is a
# new plan rather than a new driver function.
#
# The rules this engine exists to keep:
#
#   rule 1  it runs the thing. A plan that cannot be executed is not a verdict.
#   rule 2  the criterion is written to the package BEFORE the fault is injected. A threshold
#           chosen after seeing the number is not a measurement, and reading the file in
#           order is the only way a reviewer can tell the difference.
#   rule 3  the baseline must pass first. If the harness cannot demonstrate the good state,
#           the bad state proves nothing — that is BLOCKED, not NOT REPRODUCED.
#   rule 4  UNKNOWN anywhere the decision depends on it is INCONCLUSIVE. Never a negative.

# A record is one array element; fields inside it are separated by US (0x1f) so that regexes,
# URLs and CLI commands can contain anything short of a control character.
MEASURE_FS=$'\x1f'

PLAN_PROBES=()      # id FS kind FS arg FS arg ...
PLAN_FAULTS=()      # kind FS arg FS arg ...
PLAN_BASELINE=()    # id FS op FS value FS why
PLAN_CRITERIA=()    # id FS op FS value FS group
PLAN_SYMPTOM=""     # one sentence: what the customer says goes wrong
PLAN_SOURCE=""      # where the plan came from, for the report

MEASURE_IDS=()
MEASURE_BEFORE=()
MEASURE_AFTER=()

plan_reset() {
  PLAN_PROBES=(); PLAN_FAULTS=(); PLAN_BASELINE=(); PLAN_CRITERIA=()
  PLAN_SYMPTOM=""; PLAN_SOURCE=""
  MEASURE_IDS=(); MEASURE_BEFORE=(); MEASURE_AFTER=()
}

_join_fs() { local IFS="$MEASURE_FS"; printf '%s' "$*"; }

plan_probe()    { PLAN_PROBES+=("$(_join_fs "$@")"); }
plan_fault()    { PLAN_FAULTS+=("$(_join_fs "$@")"); }
plan_symptom()  { PLAN_SYMPTOM="$1"; }
plan_source()   { PLAN_SOURCE="$1"; }

# plan_criterion <probe-id> <op> [value] [group]
#
# Criteria in the same group are OR'd; groups are AND'd. Ungrouped criteria each stand
# alone, so the default is AND.
#
# The group exists because of how customers write cases. A case quoting three exception
# classes is not promising all three will appear — it is describing one failure that
# produced them. AND-ing them makes a run that reproduced the symptom report NOT
# REPRODUCED because the second-order stack trace happened not to be logged this time.
plan_criterion() {
  local id="$1" op="$2" val="${3:-}" grp="${4:-}"
  [[ -z "$grp" ]] && grp="solo:$id:${#PLAN_CRITERIA[@]}"
  PLAN_CRITERIA+=("$(_join_fs "$id" "$op" "$val" "$grp")")
}

# plan_baseline_require <probe-id> <op> <value> <why it means the harness is broken>
plan_baseline_require() { PLAN_BASELINE+=("$(_join_fs "$@")"); }

plan_is_empty() {
  declare -p PLAN_PROBES >/dev/null 2>&1 || return 0
  (( ${#PLAN_PROBES[@]} == 0 || ${#PLAN_CRITERIA[@]} == 0 ))
}

# --- comparison -----------------------------------------------------------------------
# measure_cmp <op> <before> <after> <expected>
#   0 = the criterion holds   1 = it does not   2 = undecidable
#
# Undecidable is a distinct exit on purpose. Collapsing it into "does not hold" is how a
# harness reports a healthy product from a probe that never returned a reading.
measure_cmp() {
  local op="$1" before="$2" after="$3" want="${4:-}"
  local numeric_re='^-?[0-9]+$'

  # `[[ ]] && return` reads fine but leaks a 1 out of the branch; use if, per the house rule.
  case "$op" in
    changed|unchanged|increased|decreased|increased_by|decreased_by)
      if [[ "$before" == "UNKNOWN" || "$after" == "UNKNOWN" ]]; then return 2; fi ;;
    *)
      if [[ "$after" == "UNKNOWN" ]]; then return 2; fi ;;
  esac

  case "$op" in
    eq)           [[ "$after" == "$want" ]] ;;
    ne)           [[ "$after" != "$want" ]] ;;
    contains)     grep -qE -- "$want" <<<"$after" ;;
    not_contains) ! grep -qE -- "$want" <<<"$after" ;;
    changed)      [[ "$before" != "$after" ]] ;;
    unchanged)    [[ "$before" == "$after" ]] ;;
    gt|ge|lt|le)
      [[ "$after" =~ $numeric_re && "$want" =~ $numeric_re ]] || return 2
      case "$op" in
        gt) (( after >  want )) ;;
        ge) (( after >= want )) ;;
        lt) (( after <  want )) ;;
        le) (( after <= want )) ;;
      esac ;;
    increased|decreased)
      [[ "$before" =~ $numeric_re && "$after" =~ $numeric_re ]] || return 2
      if [[ "$op" == increased ]]; then (( after > before )); else (( after < before )); fi ;;
    increased_by|decreased_by)
      [[ "$before" =~ $numeric_re && "$after" =~ $numeric_re && "$want" =~ $numeric_re ]] || return 2
      if [[ "$op" == increased_by ]]; then (( after - before >= want ))
      else (( before - after >= want )); fi ;;
    *) warn "unknown comparison operator '$op' — treated as undecidable"; return 2 ;;
  esac
}

measure_index_of() {
  local want="$1" i
  for (( i=0; i<${#MEASURE_IDS[@]}; i++ )); do
    if [[ "${MEASURE_IDS[$i]}" == "$want" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

# --- execution --------------------------------------------------------------------------

# Take every probe in the plan into the named phase array.
measure_take_all() {
  local phase="$1" rec id kind val
  local -a f=()
  PROBE_PHASE="$phase"
  for rec in "${PLAN_PROBES[@]}"; do
    IFS="$MEASURE_FS" read -r -a f <<<"$rec"
    id="${f[0]}"; kind="${f[1]}"
    val="$(probe_take "$id" "$kind" "${f[@]:2}" || true)"
    [[ -z "$val" ]] && val="UNKNOWN"
    if [[ "$phase" == "before" ]]; then
      MEASURE_IDS+=("$id"); MEASURE_BEFORE+=("$val")
    else
      MEASURE_AFTER+=("$val")
    fi
    info "probe [$phase] $id ($kind) = $val"
  done
}

# The artifact that makes the result honest: written before anything is injected.
measure_write_plan() {
  local f="$PKG/evidence/measurement-plan.txt" rec
  local -a p=()
  {
    printf 'MEASUREMENT PLAN — written before the fault was injected\n'
    printf 'generated : %s\n' "$(ts)"
    printf 'source    : %s\n' "${PLAN_SOURCE:-NOT PROVIDED}"
    printf 'symptom   : %s\n\n' "${PLAN_SYMPTOM:-NOT PROVIDED}"

    printf 'Probes (taken before the fault and again after it)\n'
    for rec in "${PLAN_PROBES[@]}"; do
      IFS="$MEASURE_FS" read -r -a p <<<"$rec"
      printf '  %-24s %-20s %s\n' "${p[0]}" "${p[1]}" "${p[*]:2}"
    done

    printf '\nBaseline requirements (if any fails the run is BLOCKED, not negative)\n'
    if (( ${#PLAN_BASELINE[@]} == 0 )); then
      printf '  (none declared)\n'
    else
      for rec in "${PLAN_BASELINE[@]}"; do
        IFS="$MEASURE_FS" read -r -a p <<<"$rec"
        printf '  %-24s %-14s %-12s  %s\n' "${p[0]}" "${p[1]}" "${p[2]}" "${p[3]:-}"
      done
    fi

    printf '\nFault to inject\n'
    if (( ${#PLAN_FAULTS[@]} == 0 )); then
      printf '  (none — the configuration under test is itself the fault)\n'
    else
      for rec in "${PLAN_FAULTS[@]}"; do
        IFS="$MEASURE_FS" read -r -a p <<<"$rec"
        printf '  %-20s %s\n' "${p[0]}" "${p[*]:1}"
      done
    fi

    printf '\nSuccess criterion — every group must hold for REPRODUCED;\n'
    printf 'within a named group one holding member is enough.\n'
    for rec in "${PLAN_CRITERIA[@]}"; do
      IFS="$MEASURE_FS" read -r -a p <<<"$rec"
      local grp="${p[3]:-}"
      [[ "$grp" == solo:* ]] && grp="(on its own)"
      printf '  %-36s %-14s %-10s %s\n' "${p[0]}" "${p[1]}" "${p[2]:-}" "$grp"
    done
    printf '\nAny probe this decision depends on returning UNKNOWN makes the run INCONCLUSIVE.\n'
  } >"$f"
  ok "measurement plan recorded up front: evidence/measurement-plan.txt"
}

measure_write_results() {
  local f="$PKG/evidence/measurement.txt" i
  {
    printf 'MEASUREMENT — before vs after\n\n'
    printf '%-24s %-20s %-20s\n' "probe" "before" "after"
    printf '%-24s %-20s %-20s\n' "------------------------" "--------------------" "--------------------"
    for (( i=0; i<${#MEASURE_IDS[@]}; i++ )); do
      printf '%-24s %-20s %-20s\n' "${MEASURE_IDS[$i]}" \
             "${MEASURE_BEFORE[$i]}" "${MEASURE_AFTER[$i]:-not taken}"
    done
    printf '\nInjected:\n%s\n' "${FAULT_LOG:-(nothing)}"
  } >"$f"
  return 0
}

# The baseline gate. A requirement that fails means the lab could not show the good state,
# so nothing measured after the fault distinguishes the product from the harness.
measure_check_baseline() {
  local rec id op want why idx val rc
  local -a b=()
  (( ${#PLAN_BASELINE[@]} == 0 )) && return 0
  step "Baseline — the harness must demonstrate the working state first"
  for rec in "${PLAN_BASELINE[@]}"; do
    IFS="$MEASURE_FS" read -r -a b <<<"$rec"
    id="${b[0]}"; op="${b[1]}"; want="${b[2]:-}"; why="${b[3]:-}"
    idx="$(measure_index_of "$id" || true)"
    if [[ -z "$idx" ]]; then
      blocked "baseline requirement names probe '$id', which the plan never takes. The plan is inconsistent; no verdict is possible."
    fi
    val="${MEASURE_BEFORE[$idx]}"
    rc=0; measure_cmp "$op" "$val" "$val" "$want" || rc=$?
    case "$rc" in
      0) ok "baseline ok: $id $op ${want} (measured $val)" ;;
      2) blocked "baseline probe '$id' returned UNKNOWN, so the harness never demonstrated the working state.
       ${why:-Without a passing baseline any post-fault reading is unattributable.}" ;;
      *) blocked "baseline FAILED: $id measured '$val', the plan required '$op $want'.
       ${why:-The lab could not show the good state, so the bad state proves nothing about the product.}" ;;
    esac
  done
  return 0
}

measure_inject() {
  local rec
  local -a f=()
  if (( ${#PLAN_FAULTS[@]} == 0 )); then fault_none; return 0; fi
  for rec in "${PLAN_FAULTS[@]}"; do
    IFS="$MEASURE_FS" read -r -a f <<<"$rec"
    if ! fault_inject "${f[@]}"; then return 1; fi
  done
  return 0
}

measure_decide() {
  local rec id op want grp idx before after rc g
  local -a c=()
  local -a groups=()
  local -a detail=()
  local groups_held=0 groups_failed=0 groups_unknown=0

  # Distinct groups, in declaration order.
  for rec in "${PLAN_CRITERIA[@]}"; do
    IFS="$MEASURE_FS" read -r -a c <<<"$rec"
    grp="${c[3]:-solo}"
    local seen=0 existing
    for existing in ${groups[@]+"${groups[@]}"}; do
      if [[ "$existing" == "$grp" ]]; then seen=1; break; fi
    done
    if (( seen == 0 )); then groups+=("$grp"); fi
  done

  for g in "${groups[@]}"; do
    local g_held=0 g_unknown=0 g_failed=0
    local -a g_detail=()
    for rec in "${PLAN_CRITERIA[@]}"; do
      IFS="$MEASURE_FS" read -r -a c <<<"$rec"
      [[ "${c[3]:-solo}" == "$g" ]] || continue
      id="${c[0]}"; op="${c[1]}"; want="${c[2]:-}"
      idx="$(measure_index_of "$id" || true)"
      if [[ -z "$idx" ]]; then
        g_unknown=$((g_unknown+1)); g_detail+=("$id: never measured"); continue
      fi
      before="${MEASURE_BEFORE[$idx]}"
      after="${MEASURE_AFTER[$idx]:-UNKNOWN}"
      rc=0; measure_cmp "$op" "$before" "$after" "$want" || rc=$?
      case "$rc" in
        0) g_held=$((g_held+1));       g_detail+=("$id $op ${want}: HOLDS (before=$before after=$after)") ;;
        2) g_unknown=$((g_unknown+1)); g_detail+=("$id $op ${want}: UNDECIDABLE (before=$before after=$after)") ;;
        *) g_failed=$((g_failed+1));   g_detail+=("$id $op ${want}: does not hold (before=$before after=$after)") ;;
      esac
    done
    # Within a group one holding member is enough; undecidable only matters when nothing held.
    if   (( g_held > 0 ));    then groups_held=$((groups_held+1))
    elif (( g_unknown > 0 )); then groups_unknown=$((groups_unknown+1))
    else                           groups_failed=$((groups_failed+1)); fi
    detail+=("${g_detail[@]}")
  done

  local joined; joined="$(printf '%s; ' "${detail[@]}")"; joined="${joined%; }"

  if (( groups_unknown > 0 )); then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the symptom could not be decided from data — $joined"
  elif (( groups_failed == 0 && groups_held > 0 )); then
    VERDICT="REPRODUCED"
    VERDICT_WHY="every criterion declared before the fault holds after it — $joined"
  else
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="the declared symptom did not occur in this lab — $joined"
  fi
  return 0
}

# measure_run — the whole sequence. Returns 1 without setting a verdict when there is no
# usable plan, so the caller can fall back to the log-signature reading.
measure_run() {
  if plan_is_empty; then
    info "no measurement plan for this case — falling back to the log-signature reading"
    return 1
  fi
  step "Generic measurement engine — ${#PLAN_PROBES[@]} probe(s), ${#PLAN_CRITERIA[@]} criterion/criteria"
  measure_write_plan

  measure_take_all before
  measure_check_baseline

  if ! measure_inject; then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the fault was never injected, so the post-fault reading says nothing about the product: ${FAULT_FAILED_REASON:-reason not recorded}"
    measure_take_all after
    measure_write_results
    DEVIATIONS+=("Injection failed: ${FAULT_FAILED_REASON:-unrecorded}. The run measured an un-faulted system; the verdict is INCONCLUSIVE rather than negative for that reason.")
    return 0
  fi

  measure_take_all after
  measure_decide
  measure_guard_negative
  measure_write_results
  return 0
}

# A negative verdict is a claim about the customer's system, and it is only worth making if
# some part of the customer's system was actually in the lab.
#
# The case that forced this: an EAP deadlock case, derived plan, stock standalone.xml, the
# harness's own three-servlet WAR. Load was applied, the customer's WFLYSRV0295 did not
# appear, and the run said NOT REPRODUCED. But the customer's deadlock is between an EJB
# timer and the web tier, and the lab deployed neither — the run never executed a line of
# their code under a line of their configuration. The only honest reading is that nothing
# was learned.
#
# Both halves matter. With the customer's configuration loaded, a negative says their
# configuration does not produce it here. With the customer's artifact deployed, it says
# their code does not. With neither, it says stock EAP running our own test application did
# not spontaneously log their error, which was never in question.
#
# Scope: derived plans only. A stated plan.env is an analyst asserting this measurement
# answers the question, and rule 5 says a stated thing is used as stated.
measure_guard_negative() {
  [[ "$VERDICT" == "NOT REPRODUCED" ]] || return 0
  [[ "$PLAN_SOURCE" == INFERRED* ]] || return 0
  if [[ "${CUSTOMER_CONFIG_APPLIED:-0}" == "1" ]]; then return 0; fi
  if [[ "${CUSTOMER_APP_APPLIED:-0}" == "1" ]]; then return 0; fi

  warn "downgrading NOT REPRODUCED to INCONCLUSIVE — neither the customer's configuration nor their application was in this lab"
  VERDICT="INCONCLUSIVE"
  VERDICT_WHY="the symptom did not occur, but nothing of the customer's system was under test: the plan was derived rather than stated, the shipped configuration was used, and the application was this harness's own. A negative here is about the lab's coverage, not about the product. Original reading: $VERDICT_WHY"
  DEVIATIONS+=("Verdict downgraded to INCONCLUSIVE: the run used the shipped configuration and the harness's own test application, so the absence of the customer's symptom is not attributable to the product. Supply input/configs/<their standalone*.xml>, input/attachments/<their .war>, or a stated input/plan.env, and re-run.")
  return 0
}
