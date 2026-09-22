#!/usr/bin/env bash
# selftest-measure.sh — exercises the decision logic of the generic engine without starting
# a product. It checks the two things that would be dangerous to get wrong: the comparison
# table, and that UNKNOWN never becomes a negative verdict.
#
#   ./tools/selftest-measure.sh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT/lib"
export LIB_DIR

# Minimal stand-ins for the run context the engine normally has.
PKG="$(mktemp -d)"; export PKG
mkdir -p "$PKG"/{logs,nodes,config} "$PKG"/evidence/{before,during,after}
COMMANDS_LOG="$PKG/commands.log"; : >"$COMMANDS_LOG"
WS_DIR="$PKG"; WS_BIND="127.0.0.1"; WS_NAME="selftest"
DEVIATIONS=()
VERDICT=""; VERDICT_WHY=""
export PKG COMMANDS_LOG WS_DIR WS_BIND WS_NAME

ts()   { date '+%H:%M:%S'; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
warn() { printf '   warn %s\n' "$*" >&2; }   # stderr, so it cannot land inside a $( ) capture
step() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
slugify() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40; }
blocked() { printf 'BLOCKED: %s\n' "$*"; exit 4; }
assert_in_pkg() { case "$(realpath -m "$1")" in "$(realpath -m "$PKG")"/*) return 0;; *) exit 9;; esac; }
port_open() { return 1; }
java_pid_for() { return 1; }
view_size() { return 1; }

source "$LIB_DIR/probe.sh"
source "$LIB_DIR/fault.sh"
source "$LIB_DIR/measure.sh"

PASS=0; FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then PASS=$((PASS+1)); printf '  PASS  %-52s %s\n' "$name" "$got"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s want=%s got=%s\n' "$name" "$want" "$got"; fi
}

cmp_result() { # op before after want -> true|false|undecidable
  local rc=0
  measure_cmp "$1" "$2" "$3" "${4:-}" || rc=$?
  case "$rc" in 0) printf 'true';; 2) printf 'undecidable';; *) printf 'false';; esac
}

step "comparison table"
check "eq 404 == 404"                 true        "$(cmp_result eq '' 404 404)"
check "eq 200 != 404"                 false       "$(cmp_result eq '' 200 404)"
check "gt 3 > 0"                      true        "$(cmp_result gt '' 3 0)"
check "gt 0 > 0"                      false       "$(cmp_result gt '' 0 0)"
check "le 2 <= 2"                     true        "$(cmp_result le '' 2 2)"
check "increased 1 -> 5"              true        "$(cmp_result increased 1 5)"
check "increased 5 -> 5"              false       "$(cmp_result increased 5 5)"
check "decreased 3 -> 1"              true        "$(cmp_result decreased 3 1)"
check "increased_by >= 100"           true        "$(cmp_result increased_by 100 250 100)"
check "increased_by short of target"  false       "$(cmp_result increased_by 100 150 100)"
check "changed ok -> fail"            true        "$(cmp_result changed ok fail)"
check "unchanged ok -> ok"            true        "$(cmp_result unchanged ok ok)"
check "contains regex hit"            true        "$(cmp_result contains '' 'handshake_failure' 'handshake')"
check "not_contains regex miss"       true        "$(cmp_result not_contains '' 'all good' 'ERROR')"

step "UNKNOWN is never a negative"
check "eq with UNKNOWN after"         undecidable "$(cmp_result eq '' UNKNOWN 404)"
check "gt with UNKNOWN after"         undecidable "$(cmp_result gt '' UNKNOWN 0)"
check "increased with UNKNOWN before" undecidable "$(cmp_result increased UNKNOWN 5)"
check "gt with non-numeric reading"   undecidable "$(cmp_result gt '' open 0)"
check "unknown operator"              undecidable "$(cmp_result wobble 1 2 3)"

step "end to end: a symptom that occurs"
plan_reset
printf 'boot ok\n' >"$PKG/logs/server.log"
plan_probe errs log_count 'IJ000453'
plan_criterion errs increased
plan_fault none
# fault_none injects nothing, so make the "after" world differ the way a product would.
fault_none() { printf 'IJ000453: Unable to get managed connection\n' >>"$PKG/logs/server.log"; return 0; }
measure_run >/dev/null
check "verdict when the error appears"  "REPRODUCED" "$VERDICT"

step "end to end: a symptom that does not occur"
plan_reset
: >"$PKG/logs/server.log"
fault_none() { return 0; }
plan_probe errs log_count 'IJ000453'
plan_criterion errs increased
plan_fault none
measure_run >/dev/null
check "verdict when it never appears"   "NOT REPRODUCED" "$VERDICT"

step "a negative from an all-stock lab is not attributable"
plan_reset
: >"$PKG/logs/server.log"
plan_probe errs log_count 'IJ000453'
plan_criterion errs increased
plan_fault none
plan_source "INFERRED from case.txt — derived"
CUSTOMER_CONFIG_APPLIED=0; CUSTOMER_APP_APPLIED=0
measure_run >/dev/null
check "derived + stock config + stock app"  "INCONCLUSIVE" "$VERDICT"

plan_reset
plan_probe errs log_count 'IJ000453'
plan_criterion errs increased
plan_fault none
plan_source "INFERRED from case.txt — derived"
CUSTOMER_CONFIG_APPLIED=1
measure_run >/dev/null
check "but the customer's config makes it stand" "NOT REPRODUCED" "$VERDICT"
CUSTOMER_CONFIG_APPLIED=0

plan_reset
plan_probe errs log_count 'IJ000453'
plan_criterion errs increased
plan_fault none
plan_source "input/plan.env (stated, not derived)"
measure_run >/dev/null
check "and a stated plan is never downgraded"  "NOT REPRODUCED" "$VERDICT"

step "end to end: the fault failed to inject"
plan_reset
plan_probe errs log_count 'IJ000453'
plan_criterion errs increased
plan_fault load 'http://127.0.0.1:1/nothing' 1 1   # nothing is listening on port 1
measure_run >/dev/null
check "failed injection is INCONCLUSIVE"  "INCONCLUSIVE" "$VERDICT"
check "and it is recorded as a deviation" "yes" \
      "$(if [[ "${DEVIATIONS[*]}" == *"Injection failed"* ]]; then echo yes; else echo no; fi)"

step "end to end: an undecidable probe"
plan_reset
plan_probe missing cluster_view 0          # no node logs exist -> UNKNOWN
plan_criterion missing eq 3
plan_fault none
measure_run >/dev/null
check "UNKNOWN probe is INCONCLUSIVE"   "INCONCLUSIVE" "$VERDICT"

step "the criterion is on disk before the fault"
check "measurement-plan.txt written"    "yes" \
      "$(if [[ -s "$PKG/evidence/measurement-plan.txt" ]]; then echo yes; else echo no; fi)"
check "it names the criterion"          "yes" \
      "$(if grep -q 'Success criterion' "$PKG/evidence/measurement-plan.txt"; then echo yes; else echo no; fi)"

step "a stated plan.env is loaded and used as stated"
source "$LIB_DIR/plan.sh"
NODE_COUNT=1; export NODE_COUNT
mkdir -p "$PKG/input"
cp /dev/null "$PKG/issue.txt"
cat >"$PKG/input/plan.env" <<'PLAN'
plan_symptom "the endpoint answers 503 once the pool is full"
plan_probe answers log_count 'STATED-MARKER'
plan_criterion answers gt 0
plan_fault none
PLAN
printf 'STATED-MARKER seen once\n' >"$PKG/logs/server.log"
build_plan >/dev/null
check "plan.env supplies the probes"      "1"    "${#PLAN_PROBES[@]}"
check "and is recorded as stated"         "yes"  "$(if [[ "$PLAN_SOURCE" == *"stated, not derived"* ]]; then echo yes; else echo no; fi)"
measure_run >/dev/null
check "and decides the verdict"           "REPRODUCED" "$VERDICT"
check "the plan.env is kept in the package" "yes" \
      "$(if [[ -f "$PKG/config/plan.env" ]]; then echo yes; else echo no; fi)"
rm -f "$PKG/input/plan.env"

step "an empty plan falls through rather than deciding"
plan_reset
rc=0; measure_run >/dev/null || rc=$?
check "measure_run returns 1 with no plan" "1" "$rc"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
rm -rf "$PKG"
(( FAIL == 0 ))
