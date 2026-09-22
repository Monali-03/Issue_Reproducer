#!/usr/bin/env bash
# flow.sh — the run order for each product. Each workspace's run.sh is a two-line wrapper
# around one of the flows below.

# --- shared CLI ---------------------------------------------------------------
usage() {
  cat <<EOF
$WS_PRODUCT_LABEL reproducer — workspace '$WS_NAME'

  ./run.sh                     reproduce the case in input/case.txt
  ./run.sh --nodes N           override the node count
  ./run.sh --scenario NAME     override scenario detection
                               (cluster-formation session-failover clustering cache xsite
                                memory deadlock
                                cpu-gc tls datasource deployment generic)
  ./run.sh --keep-running      leave the environment up after the run
  ./run.sh --allow-jdk-substitute
                               proceed on a different JDK when the one the case names is
                               not installed (recorded as a deviation)
  ./run.sh --clean             stop anything this workspace left running, free its ports
  ./run.sh --help

Input goes in  $WS_DIR/input/
  case.txt       the scenario (required)
  configs/       standalone.xml / infinispan.xml / jvm flags
  logs/          customer logs
  dumps/         thread dumps, heap dumps
  attachments/   anything else, including the customer's own WAR

Output lands in $WS_DIR/output/<case>-<timestamp>/  (and output/latest)

This workspace reads ONLY its own input/ and owns ports in the ${WS_OFFSET_BASE} block,
so the other three products can run at the same time without interfering.
EOF
}

parse_args() {
  FORCE_NODES=""; FORCE_SCENARIO=""; KEEP_RUNNING=0; DO_CLEAN=0; ALLOW_JDK_SUBSTITUTE=0
  while (( $# )); do
    case "$1" in
      --nodes)    FORCE_NODES="${2:-}"; shift 2 ;;
      --scenario) FORCE_SCENARIO="${2:-}"; shift 2 ;;
      --keep-running) KEEP_RUNNING=1; shift ;;
      --allow-jdk-substitute) ALLOW_JDK_SUBSTITUTE=1; shift ;;
      --clean)    DO_CLEAN=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

# --clean stops only processes this workspace started, identified by the node-name property
# that no other workspace uses. There is no safe broad pattern.
do_clean() {
  local pat pid killed=0
  step "Cleaning workspace '$WS_NAME'"
  for pat in "jboss.node.name=node" "infinispan.node.name=dg" "ReproWorkload"; do
    while read -r pid; do
      [[ -z "$pid" ]] && continue
      # Only ours: the process must be running out of this workspace's output tree.
      if ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$WS_DIR/output"; then
        info "killing pid $pid ($(ps -p "$pid" -o comm= 2>/dev/null))"
        kill -TERM "$pid" 2>/dev/null || true
        killed=$((killed+1))
      fi
    done < <(pgrep -f "$pat" 2>/dev/null || true)
  done
  rm -f "$WS_DIR/.run.lock"
  sleep 3
  (( killed == 0 )) && info "nothing of this workspace was running"
  ok "cleaned ($killed process(es) signalled); other workspaces untouched"
}

# --- common preamble ----------------------------------------------------------
begin_run() {
  parse_args "$@"
  (( DO_CLEAN )) && { do_clean; exit 0; }

  DEVIATIONS=(); BOOT_ERRORS=0
  VERDICT="INCONCLUSIVE"; VERDICT_WHY="the run did not reach a measurement"
  export DEVIATIONS BOOT_ERRORS

  acquire_ws_lock
  step "$WS_PRODUCT_LABEL reproducer — workspace '$WS_NAME'"

  load_case
  validate_case_product

  SCENARIO="${FORCE_SCENARIO:-$(detect_scenario)}"
  [[ -n "$FORCE_SCENARIO" ]] && info "scenario forced to '$SCENARIO'" \
                             || info "scenario detected: '$SCENARIO'"

  if [[ -n "$FORCE_NODES" ]]; then
    NODE_COUNT="$FORCE_NODES"; NODE_COUNT_SRC="--nodes on the command line"
  else
    NODE_COUNT="$(detect_node_count)"
    if grep -qoiE '[0-9]+[[:space:]]*(node|server|instance|pod)s?' "$CASE_FILE" 2>/dev/null; then
      NODE_COUNT_SRC="stated in the case"
    else
      NODE_COUNT_SRC="INFERRED (workspace default for '$SCENARIO')"
    fi
  fi
  info "topology: $NODE_COUNT node(s) — $NODE_COUNT_SRC"

  init_package
  GATE_SUMMARY=""
  export SCENARIO NODE_COUNT NODE_COUNT_SRC GATE_SUMMARY
}

# What decides the measurement path. Normally the detected scenario, but a plan the analyst
# wrote down outranks a scenario this harness guessed from keywords: rule 5, the case is
# authoritative, and input/plan.env is the case stated precisely. It is also the escape
# hatch for an issue whose shape the detector has never seen — which, given every week
# brings a new one, is most of them.
# It runs inside $( ), so it prints the key and nothing else — an info line here would be
# captured into the key and match no arm.
dispatch_key() {
  if [[ -f "$WS_DIR/input/plan.env" ]]; then printf 'stated-plan'
  else printf '%s' "$SCENARIO"; fi
}

# When there is nothing measurable as a before/after observation, the honest fallback is
# whether the customer's own error signature appears in this run's logs. Codes are taken
# from the case, never invented.
verdict_by_log_signature() {
  local codes hits=0 c found=""
  codes="$(grep -hoE '(WFLY[A-Z]*[0-9]{4,}|ISPN[0-9]{6}|IJ[0-9]{6}|JBWEB[0-9]+|JBAS[0-9]+|java\.[a-zA-Z.]+(Exception|Error))' \
           "$PKG/issue.txt" 2>/dev/null | sort -u || true)"
  if [[ -z "$codes" ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the case states no error code or exception class, and this scenario has no injectable failure step, so there was nothing decidable to measure. Add the exact error text to case.txt and re-run."
    return 0
  fi
  : >"$PKG/evidence/after/signature-search.txt"
  for c in $codes; do
    local n
    n="$(grep -rhoF -- "$c" "$PKG"/logs/ "$PKG"/evidence/ 2>/dev/null | wc -l || true)"
    printf '%-40s %s occurrence(s) in this run\n' "$c" "${n:-0}" >>"$PKG/evidence/after/signature-search.txt"
    if [[ "${n:-0}" != "0" ]]; then hits=$((hits+1)); found+="${found:+, }$c"; fi
  done
  cat "$PKG/evidence/after/signature-search.txt"
  if (( hits > 0 )); then
    VERDICT="REPRODUCED"
    VERDICT_WHY="the customer's error signature appeared in this run's own logs: $found (counts in evidence/after/signature-search.txt)"
  else
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="none of the error signatures from the case ($(tr '\n' ' ' <<<"$codes")) appeared in this run. The environment started clean and served requests; see configuration-diff.txt for what was not matched."
    # Same attribution rule as the engine: an all-stock lab cannot produce a negative about
    # the customer's system. This path is even weaker than a derived plan, since it only
    # greps for text rather than exercising anything.
    PLAN_SOURCE="INFERRED (log-signature reading — no measurement plan)"
    measure_guard_negative
  fi
}

# --- EAP ------------------------------------------------------------------------
flow_eap() {
  begin_run "$@"
  trap 'eap_stop_all 2>/dev/null || true; rm -f "$WS_DIR/.run.lock"' EXIT

  # The HA profile is only right when there is a cluster; using it for a single node adds
  # subsystems that are not in the customer's picture and can invent their own noise.
  if (( NODE_COUNT > 1 )); then SERVER_CONFIG="$WS_CONFIG_HA"
  else SERVER_CONFIG="$WS_CONFIG_SINGLE"; fi
  export SERVER_CONFIG
  info "server config: $SERVER_CONFIG"

  eap_discover
  eap_resolve_jdk
  eap_plan_ports "$NODE_COUNT"
  eap_seed_nodes "$NODE_COUNT"
  eap_apply_customer_config

  local blueprint="simple-web"
  APP_PROBE="info"
  case "$SCENARIO" in
    session-failover|clustering|cache|cluster-formation) blueprint="session-cluster"; APP_PROBE="session" ;;
  esac
  export APP_PROBE

  # Measure the host before running anything against it. When a cluster does not form, the
  # two candidate defendants are the configuration and the machine; the package has to carry
  # enough about the machine to tell them apart.
  if (( NODE_COUNT > 1 )); then
    diag_host_network "$PKG/evidence/before/host-network.txt"
    eap_select_stack
    case "$JG_STACK" in
      udp) diag_multicast "$PKG/evidence/before"; eap_apply_udp ;;
      *)   eap_apply_tcpping ;;
    esac
  else
    JG_STACK="tcp"; export JG_STACK
  fi

  eap_build_app "$blueprint"
  eap_deploy
  eap_start_nodes
  # Correct a boot failure the harness caused before letting a gate report it as a finding.
  eap_autofix_boot

  # For a deployment case the 404 IS the symptom, and for a cluster-formation case the
  # cluster of one is; blocking on either would refuse to reproduce the thing under
  # investigation. Both gates then measure and record instead.
  [[ "$SCENARIO" == "deployment" ]] && export GATE4_MODE=measure
  if [[ "$SCENARIO" == "cluster-formation" ]]; then
    export GATE3_MODE=measure GATE4_MODE=measure
  fi
  eap_gates
  GATE_SUMMARY="ports listening · boot complete ($BOOT_ERRORS with errors) · cluster of $NODE_COUNT formed · endpoint verified · routing checked"

  case "$(dispatch_key)" in
    stated-plan)
      info "input/plan.env is present — the stated plan outranks the detected scenario '$SCENARIO'"
      if build_plan; then measure_run || verdict_by_log_signature
      else verdict_by_log_signature; fi
      ;;
    cluster-formation)
      if (( NODE_COUNT < 2 )); then
        blocked "a cluster-formation case needs at least 2 nodes; this run planned $NODE_COUNT.
       Re-run with:  ./run.sh --nodes 3"
      fi
      eap_measure_cluster_formation
      # Reproducing it is half the job. The other half is a fix that is proven, not ranked.
      if [[ "$VERDICT" == "REPRODUCED" ]]; then
        eap_remediate_cluster
        if [[ -n "${REMEDY_FOUND:-}" ]]; then
          VERDICT_WHY+=" A fix was then found and PROVEN on these same nodes: '${REMEDY_FOUND}' formed a cluster of $NODE_COUNT (evidence/after/remediation-ladder.txt)."
        else
          VERDICT_WHY+=" No candidate fix on the remediation ladder formed a cluster either, which points below the product configuration — see evidence/after/remediation-ladder.txt and evidence/before/host-network.txt."
        fi
      fi
      ;;
    session-failover|clustering)
      if (( NODE_COUNT < 2 )); then
        blocked "a failover case needs at least 2 nodes; this run planned $NODE_COUNT.
       Re-run with:  ./run.sh --nodes 2"
      fi
      eap_baseline_session
      if [[ "$BASELINE_REPLICATED" == "no" ]]; then
        # The symptom is already present with nothing broken. Whether that is a finding or a
        # lab fault depends entirely on whose configuration is loaded.
        if [[ "${CUSTOMER_CONFIG_APPLIED:-0}" == "1" ]]; then
          VERDICT="REPRODUCED"
          VERDICT_WHY="sessions do not replicate at all under the CUSTOMER'S OWN configuration — no node had to fail. A session created on ${EAP_NODES[0]} was unknown to ${EAP_NODES[1]} while both nodes were healthy and in the same cluster view (evidence/before/session-node2-replica.json)."
        else
          blocked "replication does not work with the SHIPPED configuration and no customer config was supplied.
       That is a lab fault, not a finding: the stock standalone-ha.xml replicates sessions.
       Put the customer's standalone*.xml in input/configs/ and re-run."
        fi
      else
        eap_kill_node 0
        eap_measure_failover
      fi
      ;;
    deployment)
      eap_measure_deployment
      ;;
    *)
      # Anything the six hand-written paths do not cover. The engine builds a plan from
      # what the case states and runs it; only a case with nothing measurable in it falls
      # through to the log-signature reading.
      info "scenario '$SCENARIO' has no hand-written path on EAP — using the generic measurement engine"
      if build_plan; then measure_run || verdict_by_log_signature
      else verdict_by_log_signature; fi
      ;;
  esac

  eap_collect_logs
  if (( KEEP_RUNNING )); then
    warn "--keep-running: the environment is still up. Stop it with ./run.sh --clean"
    trap 'rm -f "$WS_DIR/.run.lock"' EXIT
  else
    eap_stop_all
  fi
  finalize_package
}

# --- Data Grid --------------------------------------------------------------------
flow_datagrid() {
  begin_run "$@"
  trap 'dg_stop_all 2>/dev/null || true; rm -f "$WS_DIR/.run.lock"' EXIT

  DG_USER="${DG_USER:-$WS_DG_USER}"; DG_PASS="${DG_PASS:-$WS_DG_PASS}"
  CACHE_NAME="${CACHE_NAME:-$WS_CACHE_NAME}"; ENTRY_COUNT="${ENTRY_COUNT:-$WS_ENTRY_COUNT}"
  export DG_USER DG_PASS CACHE_NAME ENTRY_COUNT

  dg_discover
  dg_resolve_jdk
  dg_plan_ports "$NODE_COUNT"
  dg_seed_nodes
  dg_apply_customer_config
  # The stack the case names is the stack that runs — udp keeps the shipped MPING transport
  # and gets the host measured instead, exactly as on EAP.
  if (( NODE_COUNT > 1 )); then
    diag_host_network "$PKG/evidence/before/host-network.txt"
    dg_select_stack
    case "$DG_STACK" in
      udp) diag_multicast "$PKG/evidence/before" ;;
      *)   dg_apply_tcpping ;;
    esac
  else
    DG_STACK="tcp"; export DG_STACK
  fi
  dg_create_users
  dg_start_nodes
  dg_gates
  GATE_SUMMARY="ports listening · servers started · cluster of $NODE_COUNT formed · authenticated cache API reachable"

  dg_install_harness
  dg_baseline_cache

  case "$(dispatch_key)" in
    stated-plan)
      info "input/plan.env is present — the stated plan outranks the detected scenario '$SCENARIO'"
      if build_plan; then measure_run || verdict_by_log_signature
      else verdict_by_log_signature; fi
      ;;
    cache|clustering|session-failover|xsite)
      if [[ "$BASELINE_CACHE" == "fail" ]]; then
        if [[ "${CUSTOMER_CONFIG_APPLIED:-0}" == "1" ]]; then
          VERDICT="REPRODUCED"
          VERDICT_WHY="entries written to a healthy $NODE_COUNT-node cluster were NOT readable from every node under the CUSTOMER'S OWN configuration — no node had to fail (evidence/before/cache-baseline.txt)."
        else
          blocked "entries are not readable cluster-wide with the SHIPPED configuration and no customer infinispan.xml was supplied.
       That is a lab fault, not a finding. Put the customer's config in input/configs/."
        fi
      elif (( NODE_COUNT < 2 )); then
        VERDICT="INCONCLUSIVE"
        VERDICT_WHY="a data-loss case needs at least 2 nodes to kill one; this run had $NODE_COUNT. Re-run with ./run.sh --nodes 2"
      else
        dg_kill_node 0
        dg_measure_cache
      fi
      ;;
    *)
      info "scenario '$SCENARIO' has no hand-written path on Data Grid — using the generic measurement engine"
      if build_plan; then measure_run || verdict_by_log_signature
      else verdict_by_log_signature; fi
      ;;
  esac

  dg_collect_logs
  if (( KEEP_RUNNING )); then
    warn "--keep-running: servers still up. Stop with ./run.sh --clean"
    trap 'rm -f "$WS_DIR/.run.lock"' EXIT
  else
    dg_stop_all
  fi
  finalize_package
}

# --- JVM --------------------------------------------------------------------------
flow_jvm() {
  begin_run "$@"
  trap 'jvm_stop_all 2>/dev/null || true; rm -f "$WS_DIR/.run.lock"' EXIT

  NODE_COUNT=1; NODE_COUNT_SRC="a JVM reproduction is single-process by definition"

  jvm_resolve
  jvm_collect_flags
  jvm_logging_flags
  jvm_compile

  # The pause threshold must be declared BEFORE the run, or the number gets chosen to fit
  # whatever came out.
  PAUSE_THRESHOLD_MS="$(grep -oiE '(pause|stall|freeze)[^0-9]{0,20}([0-9]+)[[:space:]]*(ms|milli)' "$CASE_FILE" \
                        | grep -oE '[0-9]+' | head -1 || true)"
  if [[ -n "$PAUSE_THRESHOLD_MS" ]]; then
    PAUSE_THRESHOLD_SRC="stated in the case"
  else
    PAUSE_THRESHOLD_MS="$WS_PAUSE_THRESHOLD_MS"; PAUSE_THRESHOLD_SRC="INFERRED — workspace default"
  fi
  export PAUSE_THRESHOLD_MS PAUSE_THRESHOLD_SRC
  info "success criterion declared up front: GC pause > ${PAUSE_THRESHOLD_MS}ms ($PAUSE_THRESHOLD_SRC)"

  local mode; mode="$(jvm_mode_for_scenario "$SCENARIO")"
  jvm_run "$mode" "$WS_DURATION"
  GATE_SUMMARY="JDK $TARGET_JDK_MAJOR resolved · workload compiled by that JDK · customer flags accepted by the JVM · workload signalled READY before sampling"

  jvm_sample "$WS_SAMPLES" "$WS_SAMPLE_GAP"
  jvm_wait_finish $(( WS_DURATION + 120 ))

  case "$(dispatch_key)" in
    stated-plan)
              info "input/plan.env is present — the stated plan outranks the detected scenario '$SCENARIO'"
              if build_plan; then measure_run || verdict_by_log_signature
              else verdict_by_log_signature; fi ;;
    memory)   jvm_verdict_memory ;;
    deadlock) jvm_verdict_deadlock ;;
    cpu-gc)   jvm_verdict_cpu_gc ;;
    *)        info "scenario '$SCENARIO' has no hand-written path on the JVM — using the generic measurement engine"
              if build_plan; then measure_run || verdict_by_log_signature
              else verdict_by_log_signature; fi ;;
  esac

  jvm_collect_logs
  jvm_stop_all
  finalize_package
}
