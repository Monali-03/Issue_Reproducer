#!/usr/bin/env bash
# jvm.sh — OpenJDK / HotSpot reproduction driver.
#
# There is no server here: the subject is the JVM itself under the customer's own flags.
# The driver compiles a workload with the target JDK, runs it with those flags, samples it
# while it runs, and decides the verdict from the samples rather than from the log wording.

jvm_resolve() {
  local want=""
  want="$(grep -oE '[0-9]+' <<<"${CASE_JDK:-}" | head -1 || true)"
  [[ -z "$want" ]] && want="$(grep -oiE 'jdk[ -]?([0-9]+)|java[ -]?([0-9]+)' "$CASE_FILE" | grep -oE '[0-9]+' | head -1 || true)"
  if [[ -z "$want" ]]; then
    want="$WS_DEFAULT_JDK"
    warn "no JDK version stated in the case — defaulting to $want (INFERRED)"
    DEVIATIONS+=("JDK: customer's version NOT PROVIDED; reproducer used $want (a JVM finding is version-specific, so this is a real fidelity gap)")
  fi
  TARGET_JDK_MAJOR="$want"

  if JAVA_HOME="$(resolve_jdk "$want")"; then
    ok "target JDK $want at $JAVA_HOME"
  else
    warn "JDK $want is not installed. Available:"; list_jdks >&2
    # Default is to stop: a JVM-level symptom is specific to the JDK version, and a verdict
    # from a different one answers a different question. --allow-jdk-substitute is the
    # deliberate override, and it is recorded at the top of the deviation list.
    if (( ${ALLOW_JDK_SUBSTITUTE:-0} == 0 )); then
      blocked "JDK $want is required to reproduce this case and is not on this host.
       Install it (or unpack it under ~/jdks/) and re-run, or accept a substitute:
           ./run.sh --allow-jdk-substitute"
    fi
    local alt
    for alt in $WS_SUPPORTED_JDKS; do
      if JAVA_HOME="$(resolve_jdk "$alt")"; then
        want="$alt"; break
      fi
      JAVA_HOME=""
    done
    [[ -n "${JAVA_HOME:-}" ]] || blocked "no JDK at all could be resolved on this host."
    warn "substituting JDK $want — the verdict describes THAT JDK, not the customer's"
    DEVIATIONS+=("JDK: customer=${CASE_JDK:-unstated} reproducer=$want (--allow-jdk-substitute). A JVM-level symptom is version-specific; this verdict is about JDK $want and does not transfer to the customer's JDK without further checking.")
  fi
  JAVA_VERSION_FULL="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 || true)"
  export JAVA_HOME TARGET_JDK_MAJOR JAVA_VERSION_FULL
  info "$JAVA_VERSION_FULL"
}

# Customer flags come from a file if one was supplied, otherwise from the case text. They
# are used VERBATIM — rewriting them would reproduce a configuration nobody runs.
jvm_collect_flags() {
  CUSTOMER_OPTS=""
  local src
  for src in "$WS_DIR/input/configs"/jvm*.txt "$WS_DIR/input/configs"/*.conf "$WS_DIR/input/configs"/java*.opts; do
    [[ -f "$src" ]] || continue
    cp "$src" "$PKG/config/$(basename "$src")"
    # standalone.conf-style: pull the JAVA_OPTS assignment; plain lists: take the -X/-XX lines.
    local got
    # ERE has no '\-' escape; a bracket expression is the portable way to match a literal
    # dash at the start of an alternation.
    got="$(grep -hoE '[-](X|XX:|D|agentlib|javaagent)[^"'"'"' ]*' "$src" 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "$got" ]]; then
      CUSTOMER_OPTS+=" $got"
      ok "flags taken from $(basename "$src")"
    fi
  done
  if [[ -z "${CUSTOMER_OPTS// /}" ]]; then
    local got
    got="$(grep -hoE '[-](X|XX:)[^ ,]*' "$CASE_FILE" 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "$got" ]] && { CUSTOMER_OPTS="$got"; ok "flags taken from case.txt"; }
  fi
  if [[ -z "${CUSTOMER_OPTS// /}" ]]; then
    CUSTOMER_OPTS="$WS_DEFAULT_OPTS"
    CUSTOMER_CONFIG_APPLIED=0
    warn "no JVM flags supplied — using $CUSTOMER_OPTS (INFERRED)"
    DEVIATIONS+=("JVM flags: customer's flags NOT PROVIDED; reproducer used '$CUSTOMER_OPTS'. Heap size and collector choice usually decide this class of issue, so this is the largest fidelity gap in the run.")
  else
    CUSTOMER_CONFIG_APPLIED=1
    info "customer flags:$CUSTOMER_OPTS"
  fi
  # The flags are this workspace's equivalent of a customer standalone.xml, and the verdict
  # logic asks whether any of the customer's own configuration is actually loaded before it
  # allows a negative result to stand.
  export CUSTOMER_OPTS CUSTOMER_CONFIG_APPLIED
}

# GC logging is spelled differently before and after JDK 9, and getting it wrong means the
# JVM refuses to start for a reason that has nothing to do with the customer's problem.
jvm_logging_flags() {
  GC_LOG="$PKG/logs/gc.log"
  if grep -qE '[-]Xlog:gc|[-]Xloggc' <<<"$CUSTOMER_OPTS"; then
    LOG_OPTS=""
    warn "the customer's flags already configure GC logging — theirs is kept, ours not added"
    GC_LOG=""
  elif (( TARGET_JDK_MAJOR <= 8 )); then
    LOG_OPTS="-Xloggc:$GC_LOG -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCApplicationStoppedTime"
  else
    LOG_OPTS="-Xlog:gc*,safepoint:file=$GC_LOG:time,uptime,level,tags"
  fi
  HEAP_DUMP="$PKG/evidence/during/heapdump.hprof"
  if ! grep -q 'HeapDumpOnOutOfMemoryError' <<<"$CUSTOMER_OPTS"; then
    LOG_OPTS+=" -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$HEAP_DUMP"
  fi
  export GC_LOG LOG_OPTS HEAP_DUMP
}

jvm_compile() {
  step "Compiling the workload with the target JDK"
  mkdir -p "$PKG/app/classes"
  cp "$TEMPLATES_DIR/apps/jvm-workload/ReproWorkload.java" "$PKG/app/"
  local out rc=0
  out="$("$JAVA_HOME/bin/javac" -d "$PKG/app/classes" "$PKG/app/ReproWorkload.java" 2>&1)" || rc=$?
  printf '[%s] javac (exit %s)\n%s\n\n' "$(ts)" "$rc" "$out" >>"$COMMANDS_LOG"
  (( rc == 0 )) || { printf '%s\n' "$out" >&2; blocked "the workload did not compile under JDK $TARGET_JDK_MAJOR"; }
  ok "compiled with $("$JAVA_HOME/bin/javac" -version 2>&1)"
}

# Which workload matches the reported symptom.
jvm_mode_for_scenario() {
  case "$1" in
    memory)   echo leak ;;
    deadlock) echo deadlock ;;
    cpu-gc)   echo cpu ;;
    *)        echo idle ;;
  esac
}

jvm_run() {
  local mode="$1" duration="${2:-$WS_DURATION}"
  step "Running the workload (mode=$mode, ${duration}s) under the customer's flags"
  JVM_OUT="$PKG/logs/workload.log"
  : >"$JVM_OUT"

  printf '[%s] RUN java %s %s -cp classes ReproWorkload --mode %s --duration %s\n\n' \
    "$(ts)" "$CUSTOMER_OPTS" "$LOG_OPTS" "$mode" "$duration" >>"$COMMANDS_LOG"

  # shellcheck disable=SC2086
  ( cd "$PKG/app" && exec "$JAVA_HOME/bin/java" $CUSTOMER_OPTS $LOG_OPTS \
      -cp classes ReproWorkload --mode "$mode" --duration "$duration" \
      --threads "$WS_THREADS" ) >"$JVM_OUT" 2>&1 &
  JVM_PID=$!
  echo "$JVM_PID" >"$PKG/nodes/workload.pid"
  export JVM_PID JVM_OUT

  # Sampling must not start before the workload is actually working, or every sample
  # describes JVM startup rather than the symptom.
  if ! wait_for_log "$JVM_OUT" 'WORKLOAD_READY' 60; then
    if ! ps -p "$JVM_PID" >/dev/null 2>&1; then
      tail -30 "$JVM_OUT" >&2
      blocked "the JVM exited before the workload started.
       That is almost always an unrecognised flag in the customer's options — which is
       itself worth reporting, but it is not the reported symptom. Output above."
    fi
    blocked "the workload never signalled READY within 60s — see $JVM_OUT"
  fi
  ok "workload running (pid $JVM_PID)"
}

# Samples taken while the symptom is live. Thread dumps after the fact explain nothing.
jvm_sample() {
  local n="${1:-5}" gap="${2:-5}" i
  step "Sampling the live JVM ($n samples, ${gap}s apart)"
  local jcmd="$JAVA_HOME/bin/jcmd"
  for (( i=1; i<=n; i++ )); do
    ps -p "$JVM_PID" >/dev/null 2>&1 || { info "workload exited before sample $i"; break; }
    if have "$jcmd" || [[ -x "$jcmd" ]]; then
      "$jcmd" "$JVM_PID" Thread.print -l >"$PKG/evidence/during/threaddump-$i.txt" 2>&1 || true
      "$jcmd" "$JVM_PID" GC.heap_info   >>"$PKG/evidence/during/heap-$i.txt" 2>&1 || true
      (( i == 1 )) && "$jcmd" "$JVM_PID" VM.flags -all >"$PKG/evidence/before/vm-flags.txt" 2>&1 || true
    fi
    # %CPU and RSS over time — the data behind a "high CPU" or "memory growth" verdict.
    ps -p "$JVM_PID" -o pid=,pcpu=,rss=,etimes= >>"$PKG/evidence/during/ps-samples.txt" 2>/dev/null || true
    info "sample $i/$n captured"
    sleep "$gap"
  done
  ok "sampling complete"
}

jvm_wait_finish() {
  local timeout="${1:-600}" i=0
  while (( i < timeout )); do
    if ! ps -p "$JVM_PID" >/dev/null 2>&1; then
      # A non-zero exit here is the expected outcome for an OOM run, so `wait` must not be
      # left bare: under `set -e` its status would abort the script before the verdict.
      JVM_RC=0
      wait "$JVM_PID" 2>/dev/null || JVM_RC=$?
      export JVM_RC
      info "workload exited with status $JVM_RC"
      return 0
    fi
    sleep 1; ((i++))
  done
  warn "workload still running after ${timeout}s — terminating"
  kill_recorded_pid "$PKG/nodes/workload.pid" "ReproWorkload" TERM
  JVM_RC=timeout; export JVM_RC
}

# --- verdicts ----------------------------------------------------------------
jvm_verdict_memory() {
  cp "$JVM_OUT" "$PKG/evidence/after/workload.log" 2>/dev/null || true
  if grep -q 'WORKLOAD_OOM\|java.lang.OutOfMemoryError' "$JVM_OUT"; then
    VERDICT="REPRODUCED"
    # Match the thrown error, not the -XX:+HeapDumpOnOutOfMemoryError flag echoed in the
    # startup banner — that flag name contains the same substring.
    local msg
    msg="$(grep -m1 -oE 'java\.lang\.OutOfMemoryError: [^]"]+' "$JVM_OUT" || true)"
    VERDICT_WHY="the JVM threw ${msg:-java.lang.OutOfMemoryError} under the customer's flags ($CUSTOMER_OPTS)"
    [[ -f "$HEAP_DUMP" ]] && VERDICT_WHY+=" (heap dump captured at evidence/during/$(basename "$HEAP_DUMP"))"
  elif grep -q 'WORKLOAD_SURVIVED' "$JVM_OUT"; then
    local peak
    peak="$(grep -oE 'heap used=[0-9]+MB' "$JVM_OUT" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="the heap absorbed sustained retention for the full window without OutOfMemoryError (peak used ${peak:-?}MB). The customer's heap exhaustion was not provoked by this retention rate under these flags."
  else
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the workload neither reported OOM nor completed its window (exit ${JVM_RC:-?}) — see logs/workload.log"
  fi
}

jvm_verdict_deadlock() {
  local found=0 f
  for f in "$PKG/evidence/during"/threaddump-*.txt; do
    [[ -f "$f" ]] || continue
    if grep -q 'Found one Java-level deadlock' "$f"; then found=1
      cp "$f" "$PKG/evidence/after/deadlock-threaddump.txt"; break; fi
  done
  if (( found )); then
    VERDICT="REPRODUCED"
    VERDICT_WHY="the JVM's own deadlock detector reported 'Found one Java-level deadlock' in a live thread dump (evidence/after/deadlock-threaddump.txt) — not inferred from thread states"
  elif ! ls "$PKG/evidence/during"/threaddump-*.txt >/dev/null 2>&1; then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="no thread dump could be taken (jcmd unavailable or the process was not attachable), so deadlock could be neither shown nor ruled out"
  else
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="no Java-level deadlock was reported in any of $(ls "$PKG/evidence/during"/threaddump-*.txt | wc -l) live thread dumps"
  fi
}

jvm_verdict_cpu_gc() {
  local avg="" maxpause=""
  if [[ -f "$PKG/evidence/during/ps-samples.txt" ]]; then
    avg="$(awk '{s+=$2; n++} END{if(n) printf "%.1f", s/n}' "$PKG/evidence/during/ps-samples.txt" || true)"
  fi
  if [[ -n "$GC_LOG" && -f "$GC_LOG" ]]; then
    # Works for both spellings: JDK9+ "Pause Young (...) 12.345ms", JDK8 "Total time ... 0.0123 seconds".
    maxpause="$(grep -oE '[0-9]+\.[0-9]+ms' "$GC_LOG" 2>/dev/null | tr -d 'ms' | sort -n | tail -1 || true)"
    [[ -z "$maxpause" ]] && maxpause="$(grep -oE 'Total time for which application threads were stopped: [0-9.]+' "$GC_LOG" 2>/dev/null \
        | grep -oE '[0-9.]+$' | sort -n | tail -1 | awk '{printf "%.1f", $1*1000}' || true)"
  fi
  {
    printf 'average %%CPU across samples : %s\n' "${avg:-NOT MEASURED}"
    printf 'longest GC pause observed   : %s ms\n' "${maxpause:-NOT MEASURED}"
    printf 'threshold used              : %s ms (%s)\n' "$PAUSE_THRESHOLD_MS" "$PAUSE_THRESHOLD_SRC"
  } >"$PKG/evidence/after/cpu-gc-measurements.txt"

  if [[ -z "$maxpause" && -z "$avg" ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="neither CPU samples nor GC pause times could be measured, so there is nothing to compare against the customer's report"
  elif [[ -n "$maxpause" ]] && awk "BEGIN{exit !($maxpause > $PAUSE_THRESHOLD_MS)}"; then
    VERDICT="REPRODUCED"
    VERDICT_WHY="a GC pause of ${maxpause}ms was recorded, above the ${PAUSE_THRESHOLD_MS}ms threshold ($PAUSE_THRESHOLD_SRC); average CPU across samples was ${avg:-?}%"
  else
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="the longest GC pause was ${maxpause:-0}ms, under the ${PAUSE_THRESHOLD_MS}ms threshold ($PAUSE_THRESHOLD_SRC); average CPU across samples was ${avg:-?}%"
  fi
}

jvm_collect_logs() {
  cp "$JVM_OUT" "$PKG/logs/workload.log" 2>/dev/null || true
  "$JAVA_HOME/bin/java" -XX:+PrintFlagsFinal -version >"$PKG/evidence/before/jvm-default-flags.txt" 2>&1 || true
  "$JAVA_HOME/bin/java" -version >"$PKG/environment-java.txt" 2>&1 || true
  [[ -f "$GC_LOG" ]] && cp "$GC_LOG" "$PKG/evidence/after/gc.log" 2>/dev/null || true
  return 0
}

jvm_stop_all() {
  if [[ -f "$PKG/nodes/workload.pid" ]]; then
    kill_recorded_pid "$PKG/nodes/workload.pid" "ReproWorkload" TERM
  fi
  return 0
}
