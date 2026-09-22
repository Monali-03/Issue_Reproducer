#!/usr/bin/env bash
# datagrid.sh — Red Hat Data Grid / Infinispan server reproduction driver.
#
# Data Grid is not "EAP with caches": separate install, single-port protocol detection,
# digest auth against a hashed properties realm, and REST-created caches that are permanent.
# Each of those has its own way of producing a convincing false reproduction, so each is
# handled explicitly below.

dg_discover() {
  local cand="" g sub
  if [[ -n "${RHDG_HOME:-}" ]]; then
    cand="$RHDG_HOME"
  else
    for g in $WS_INSTALL_GLOB; do
      [[ -x "$g/bin/server.sh" ]] && { cand="$g"; break; }
      for sub in "$g"/*/; do
        [[ -x "${sub%/}/bin/server.sh" ]] && { cand="${sub%/}"; break 2; }
      done
    done
  fi
  [[ -n "$cand" && -x "$cand/bin/server.sh" ]] || blocked \
"no Data Grid server installation found.
       Looked under: $WS_INSTALL_GLOB
       Set it explicitly:   RHDG_HOME=/path/to/redhat-datagrid-8.x-server ./run.sh"

  RHDG_HOME="$(cd "$cand" && pwd)"
  RHDG_VERSION="$(basename "$RHDG_HOME" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  [[ -z "$RHDG_VERSION" ]] && RHDG_VERSION="UNKNOWN"
  export RHDG_HOME RHDG_VERSION
  ok "RHDG_HOME=$RHDG_HOME (version from path: $RHDG_VERSION)"

  if [[ -n "${CASE_VERSION:-}" && "$RHDG_VERSION" != "UNKNOWN" ]]; then
    local want; want="$(grep -oE '[0-9]+\.[0-9]+' <<<"$CASE_VERSION" | head -1 || true)"
    if [[ -n "$want" && "$RHDG_VERSION" != "$want"* ]]; then
      warn "customer runs $CASE_VERSION, the lab has $RHDG_VERSION — recorded as a deviation"
      DEVIATIONS+=("Data Grid version: customer=$CASE_VERSION reproducer=$RHDG_VERSION (behaviour may differ between micro-versions)")
    fi
  fi
}

dg_resolve_jdk() {
  local want="${WS_DEFAULT_JDK}" alt
  [[ -n "${CASE_JDK:-}" ]] && want="$(grep -oE '[0-9]+' <<<"$CASE_JDK" | head -1 || echo "$want")"
  if JAVA_HOME="$(resolve_jdk "$want")"; then
    ok "JDK $want at $JAVA_HOME"
  else
    warn "JDK $want is not installed. Available:"; list_jdks >&2
    # Same rule as EAP and the JVM workspace: a stated JDK is honoured or the run stops.
    if (( ${ALLOW_JDK_SUBSTITUTE:-0} == 0 )); then
      blocked "the case names JDK $want and it is not installed on this host.
       Install it and re-run — unpacking a build under ~/jdks/ is enough, no root needed:
           mkdir -p ~/jdks && tar -C ~/jdks -xf <jdk-$want-linux-x64.tar.gz>
       Or accept a substitute and have it recorded as a deviation:
           ./run.sh --allow-jdk-substitute"
    fi
    for alt in $WS_SUPPORTED_JDKS; do
      if JAVA_HOME="$(resolve_jdk "$alt")"; then
        warn "JDK $want not installed; using $alt (recorded as a deviation)"
        DEVIATIONS+=("JDK: customer=$want reproducer=$alt (--allow-jdk-substitute)")
        break
      fi
      JAVA_HOME=""
    done
    [[ -n "${JAVA_HOME:-}" ]] || { warn "no supported JDK found. Available:"; list_jdks >&2
      blocked "no JDK from '$WS_SUPPORTED_JDKS' available for Data Grid."; }
  fi
  export JAVA_HOME
}

dg_plan_ports() {
  local n="$1" i
  DG_OFFSETS=(); DG_PORTS=(); DG_JG=(); DG_NODES=(); DG_HOSTS=""
  for (( i=0; i<n; i++ )); do
    DG_OFFSETS+=($(( WS_OFFSET_BASE + i * 100 )))
    DG_PORTS+=($(( 11222 + WS_OFFSET_BASE + i * 100 )))
    # The port offset applies to the server's socket bindings, NOT to the JGroups bind
    # port — that one comes from a system property and must be set per node by hand.
    DG_JG+=($(( 7800 + WS_OFFSET_BASE + i * 100 )))
    DG_NODES+=("dg$((i+1))")
  done
  for (( i=0; i<n; i++ )); do DG_HOSTS+="${DG_HOSTS:+ }$WS_BIND:${DG_PORTS[$i]}"; done
  export DG_OFFSETS DG_PORTS DG_JG DG_NODES DG_HOSTS
  info "port plan: single-port=${DG_PORTS[*]} jgroups=${DG_JG[*]}"
  assert_ports_free "${DG_PORTS[@]}" "${DG_JG[@]}"
}

dg_seed_nodes() {
  local n="${#DG_NODES[@]}" i node dir
  step "Seeding $n isolated server roots"
  for (( i=0; i<n; i++ )); do
    node="${DG_NODES[$i]}"; dir="$PKG/nodes/$node"
    assert_in_pkg "$dir"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -r "$RHDG_HOME/server/." "$dir/"
    rm -rf "$dir/data" "$dir/log"; mkdir -p "$dir/data" "$dir/log"
  done
  ok "server roots seeded under $PKG/nodes/"
}

dg_apply_customer_config() {
  local src n applied=0 i node
  for src in "$WS_DIR/input/configs"/*.xml; do
    [[ -f "$src" ]] || continue
    n="$(basename "$src")"
    cp "$src" "$PKG/config/customer-$n"
    case "$n" in
      infinispan*.xml)
        for (( i=0; i<${#DG_NODES[@]}; i++ )); do
          node="${DG_NODES[$i]}"
          cp "$src" "$PKG/nodes/$node/conf/infinispan.xml"
        done
        ok "applied customer $n as conf/infinispan.xml on every node"
        DEVIATIONS+=("server config: customer's $n used verbatim")
        applied=1 ;;
      *) info "copied $n into the package (not auto-applied)" ;;
    esac
  done
  (( applied == 0 )) && DEVIATIONS+=("server config: NO customer infinispan.xml supplied; shipped default used (fidelity gap)")
  CUSTOMER_CONFIG_APPLIED="$applied"; export CUSTOMER_CONFIG_APPLIED
}

# Discovery overlay. Same reason as EAP: multicast between processes on one host does not
# work, and the resulting cluster-of-one looks identical to the replication bug under test.
#
# The insertion is a text edit against a config whose exact layout varies by release, so it
# is deliberately paired with the hard cluster-formation gate below: if the overlay does not
# take, the gate BLOCKS the run rather than letting it produce a false verdict.
# Which JGroups stack this run uses. Same rule as EAP: THE CASE IS AUTHORITATIVE.
#
# Data Grid's shipped default is udp/MPING. When the case names udp — or says "multicast" —
# that default is left exactly as it ships and nothing is overlaid, because the overlay would
# repair the very thing under test. tcp/TCPPING is applied only when the case asks for tcp or
# says nothing at all.
#
# DG_SKIP_TCPPING=1 still forces the shipped stack, for anyone who wants it without editing
# the case.
dg_select_stack() {
  local want; want="$(detect_stack)"
  if [[ "${DG_SKIP_TCPPING:-0}" == "1" ]]; then
    DG_STACK="udp"
    DG_STACK_SRC="DG_SKIP_TCPPING=1 in the environment — shipped udp/MPING stack, no overlay"
  elif [[ -n "$want" ]]; then
    DG_STACK="$want"
    DG_STACK_SRC="named in the case — used as stated, no override"
  else
    DG_STACK="tcp"
    DG_STACK_SRC="INFERRED — the case names no stack; tcp/TCPPING is used because it depends on nothing about the network"
    DEVIATIONS+=("JGroups stack: NOT STATED in the case; run used 'tcp' with TCPPING. Add 'udp stack' or 'tcp stack' to case.txt to pin it.")
  fi
  export DG_STACK DG_STACK_SRC
  info "JGroups stack: $DG_STACK ($DG_STACK_SRC)"
}

dg_apply_tcpping() {
  local n="${#DG_NODES[@]}" i hosts="" node cfg
  for (( i=0; i<n; i++ )); do hosts+="${hosts:+,}$WS_BIND[${DG_JG[$i]}]"; done
  step "Overlaying TCPPING discovery (initial_hosts=$hosts)"

  for (( i=0; i<n; i++ )); do
    node="${DG_NODES[$i]}"; cfg="$PKG/nodes/$node/conf/infinispan.xml"
    [[ -f "$cfg" ]] || blocked "no conf/infinispan.xml in the seeded server root for $node"

    if grep -q 'name="repro-tcpping"' "$cfg"; then continue; fi

    # The stack extends the shipped tcp stack and swaps MPING for TCPPING in place; the
    # transport then selects it through infinispan.cluster.stack, so <transport> itself is
    # left untouched.
    local block="$PKG/config/jgroups-block.xml"
    cat >"$block" <<EOF
  <jgroups>
    <stack name="repro-tcpping" extends="tcp">
      <TCPPING initial_hosts="$hosts" port_range="0" stack.combine="REPLACE" stack.position="MPING"/>
    </stack>
  </jgroups>
EOF
    # Insert immediately before the first <cache-container ...> element.
    if ! grep -q '<cache-container' "$cfg"; then
      blocked "$cfg has no <cache-container> element — cannot place the JGroups stack.
       Supply a config whose transport can be overridden, or set DG_SKIP_TCPPING=1 if the
       environment really does have working multicast."
    fi
    awk -v blockfile="$block" '
      !done && /<cache-container/ { while ((getline line < blockfile) > 0) print line; done=1 }
      { print }
    ' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg"
    grep -q 'repro-tcpping' "$cfg" || blocked "the JGroups stack overlay did not take in $cfg"
  done
  ok "TCPPING stack inserted into all $n configs"
  DEVIATIONS+=("discovery: TCPPING(initial_hosts=$hosts) on the tcp stack. This is the default only when the case does not name a stack; a case naming udp keeps the shipped udp/MPING transport untouched.")
}

dg_create_users() {
  local i node out rc=0
  step "Creating the REST/HotRod user on every node"
  for (( i=0; i<${#DG_NODES[@]}; i++ )); do
    node="${DG_NODES[$i]}"
    out="$(JAVA_HOME="$JAVA_HOME" "$RHDG_HOME/bin/cli.sh" user create "$DG_USER" \
            -p "$DG_PASS" -g admin --server-root="$PKG/nodes/$node" 2>&1)" || rc=$?
    printf '[%s] user create %s (exit %s)\n%s\n\n' "$(ts)" "$node" "$rc" "$out" >>"$COMMANDS_LOG"
    if (( rc != 0 )); then
      printf '%s\n' "$out" | tail -10 >&2
      blocked "could not create the Data Grid user on $node.
       Without credentials every cache call returns 403 — and a harness that counts 403 as
       'entry missing' reports a replication bug that does not exist."
    fi
    rc=0
  done
  ok "user '$DG_USER' created with group 'admin' on every node"
}

dg_start_nodes() {
  local n="${#DG_NODES[@]}" i node log stack_opt=""
  # Only select the overlay stack when one was actually inserted. Pointing
  # infinispan.cluster.stack at a stack that is not in the config fails the transport at boot.
  [[ "${DG_STACK:-tcp}" == "tcp" && "${DG_SKIP_TCPPING:-0}" != "1" ]] \
    && stack_opt="-Dinfinispan.cluster.stack=repro-tcpping"
  step "Starting $n Data Grid server(s)"
  for (( i=0; i<n; i++ )); do
    node="${DG_NODES[$i]}"; log="$PKG/logs/$node-console.log"
    : >"$log"
    JAVA_HOME="$JAVA_HOME" \
    JAVA_OPTS="${JAVA_OPTS:-} -Djgroups.bind.address=$WS_BIND -Djgroups.bind.port=${DG_JG[$i]} $stack_opt -Dinfinispan.node.name=$node" \
      nohup "$RHDG_HOME/bin/server.sh" \
        -s "$PKG/nodes/$node" \
        -b "$WS_BIND" \
        -o "${DG_OFFSETS[$i]}" \
        >>"$log" 2>&1 &
    printf '[%s] START %s port=%s jgroups=%s\n' "$(ts)" "$node" "${DG_PORTS[$i]}" "${DG_JG[$i]}" >>"$COMMANDS_LOG"
    info "$node starting (port ${DG_PORTS[$i]}, jgroups ${DG_JG[$i]}) -> $log"
  done

  sleep 5
  for (( i=0; i<n; i++ )); do
    node="${DG_NODES[$i]}"
    local pid="" w=0
    while (( w < 30 )); do
      pid="$(java_pid_for "infinispan.node.name=$node" || true)"
      [[ -n "$pid" ]] && break
      sleep 1; ((w++))
    done
    [[ -n "$pid" ]] || blocked "$node produced no JVM — see $PKG/logs/$node-console.log"
    echo "$pid" >"$PKG/nodes/$node.pid"
    info "$node jvm pid $pid"
  done
}

dg_gates() {
  local n="${#DG_NODES[@]}" i node log

  step "Gate 1/4 — single port listening"
  for (( i=0; i<n; i++ )); do
    wait_for_port "$WS_BIND" "${DG_PORTS[$i]}" 180 \
      || blocked "${DG_NODES[$i]} never opened ${DG_PORTS[$i]} — see $PKG/logs/${DG_NODES[$i]}-console.log"
  done
  ok "all $n servers listening"

  step "Gate 2/4 — clean start"
  for (( i=0; i<n; i++ )); do
    node="${DG_NODES[$i]}"; log="$PKG/nodes/$node/log/server.log"
    [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
    wait_for_log "$log" 'ISPN080001|ISPN080034|Datagrid Server.*started|Infinispan Server.*started' 180 \
      || blocked "$node never reported a completed start — see $log"
  done
  ok "all servers report started"

  step "Gate 3/4 — cluster formed (every node sees every node)"
  if (( n == 1 )); then
    info "single node — clustering gate not applicable"
  else
    for (( i=0; i<n; i++ )); do
      node="${DG_NODES[$i]}"; log="$PKG/nodes/$node/log/server.log"
      [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
      wait_for_log "$log" 'ISPN000094' 180 \
        || blocked "$node never logged a cluster view (ISPN000094).
       Discovery failed in the LAB. Every 'entry missing' after this would be an artifact."
      local view members
      view="$(grep 'ISPN000094' "$log" | tail -1 || true)"
      members="$(view_size "$view")"
      printf '%-6s %s\n' "$node" "$view" >>"$PKG/evidence/before/cluster-views.txt"
      (( members < n )) && blocked "$node sees only $members of $n members.
       view: $view
       A partial cluster reproduces the symptom by itself — stopping rather than fabricating."
      info "$node sees $members/$n members"
    done
    ok "cluster of $n formed"
  fi

  step "Gate 4/4 — authenticated cache API reachable"
  # /health/status answers ANONYMOUSLY. A readiness probe against it reports HEALTHY while
  # every real call returns 403, so the gate deliberately calls a real cache endpoint.
  for (( i=0; i<n; i++ )); do
    local code
    code="$(curl -sS --digest -u "$DG_USER:$DG_PASS" -o /dev/null -w '%{http_code}' \
            --max-time 15 "http://$WS_BIND:${DG_PORTS[$i]}/rest/v2/caches" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] || blocked "${DG_NODES[$i]}: /rest/v2/caches returned $code, not 200.
       The realm stores hashed credentials, so Basic auth is rejected even when the password
       is right — the harness uses digest. A 401/403 here means later 404s would be auth
       failures misread as missing entries."
    info "${DG_NODES[$i]} authenticated cache API OK"
  done
  ok "all four Data Grid gates passed"
}

# The harness writes a known set of entries and reads every one back from every node.
dg_install_harness() {
  mkdir -p "$PKG/app"
  cp "$TEMPLATES_DIR/apps/cache-harness/cache-harness.sh" "$PKG/app/"
  cp "$TEMPLATES_DIR/apps/cache-harness/cache-config.json" "$PKG/app/"
  # A customer cache definition is the real thing; prefer it.
  local cust
  cust="$(ls "$WS_DIR/input/configs"/*cache*.json "$WS_DIR/input/attachments"/*cache*.json 2>/dev/null | head -1 || true)"
  if [[ -n "$cust" ]]; then
    cp "$cust" "$PKG/app/cache-config.json"
    ok "using the customer's cache definition: $(basename "$cust")"
    DEVIATIONS+=("cache definition: customer's $(basename "$cust") used verbatim")
  fi
  chmod +x "$PKG/app/cache-harness.sh"
  cat >"$PKG/nodes.env" <<EOF
# generated by the datagrid reproducer — consumed by app/cache-harness.sh
DG_HOSTS="$DG_HOSTS"
DG_USER="$DG_USER"
DG_PASS="$DG_PASS"
CACHE_NAME="$CACHE_NAME"
ENTRY_COUNT="$ENTRY_COUNT"
EOF
}

dg_baseline_cache() {
  step "Baseline — every entry readable from every node BEFORE anything is broken"
  local rc=0
  ( cd "$PKG/app" && OUT_DIR="$PKG/evidence/before" ./cache-harness.sh create \
      && OUT_DIR="$PKG/evidence/before" ./cache-harness.sh put "$ENTRY_COUNT" \
      && OUT_DIR="$PKG/evidence/before" ./cache-harness.sh members \
      && OUT_DIR="$PKG/evidence/before" ./cache-harness.sh verify ) \
    >"$PKG/evidence/before/cache-baseline.txt" 2>&1 || rc=$?
  tail -8 "$PKG/evidence/before/cache-baseline.txt"
  case "$rc" in
    0) ok "baseline passes: $ENTRY_COUNT entries readable from all ${#DG_NODES[@]} nodes"
       BASELINE_CACHE=pass ;;
    3) blocked "baseline INCONCLUSIVE (write failures or auth/reachability problems).
       See $PKG/evidence/before/cache-baseline.txt. Nothing was broken, so this is a lab
       problem, not a finding about the customer's cache." ;;
    *) BASELINE_CACHE=fail
       warn "baseline FAILED: entries are not readable from every node before any injection" ;;
  esac
  export BASELINE_CACHE
}

dg_kill_node() {
  local idx="$1"
  local node="${DG_NODES[$idx]}"
  step "Injecting failure — killing $node"
  kill_recorded_pid "$PKG/nodes/$node.pid" "infinispan.node.name=$node" TERM
  if ! wait_for_port_closed "$WS_BIND" "${DG_PORTS[$idx]}" 45; then
    local pid; pid="$(java_pid_for "infinispan.node.name=$node" || true)"
    [[ -n "$pid" ]] && { warn "escalating to SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
    wait_for_port_closed "$WS_BIND" "${DG_PORTS[$idx]}" 30 \
      || blocked "$node would not die — a surviving node makes the result INCONCLUSIVE."
  fi
  ok "$node is down"
  # Remove it from the harness's host list: reading from a host that is intentionally dead
  # would be recorded as unreachable and drag the verdict to INCONCLUSIVE for no reason.
  local i new=""
  for (( i=0; i<${#DG_NODES[@]}; i++ )); do
    (( i == idx )) && continue
    new+="${new:+ }$WS_BIND:${DG_PORTS[$i]}"
  done
  DG_HOSTS="$new"; export DG_HOSTS
  sed -i "s|^DG_HOSTS=.*|DG_HOSTS=\"$DG_HOSTS\"|" "$PKG/nodes.env"
  info "surviving hosts: $DG_HOSTS"
}

dg_measure_cache() {
  step "Measuring — re-reading every entry from the surviving node(s)"
  local rc=0
  ( cd "$PKG/app" && OUT_DIR="$PKG/evidence/during" ./cache-harness.sh verify ) \
    >"$PKG/evidence/during/cache-after.txt" 2>&1 || rc=$?
  tail -8 "$PKG/evidence/during/cache-after.txt"
  case "$rc" in
    0) VERDICT="NOT REPRODUCED"
       VERDICT_WHY="all $ENTRY_COUNT entries were still readable from every surviving node after ${DG_NODES[0]} was killed — the data survived owner loss" ;;
    1) local miss
       miss="$(grep -oE 'misses=[0-9]+' "$PKG/evidence/during/cache-after.txt" | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo "some")"
       VERDICT="REPRODUCED"
       VERDICT_WHY="entries were lost after a node was killed ($miss failed reads out of $ENTRY_COUNT per surviving node) — the customer's reported symptom" ;;
    3) VERDICT="INCONCLUSIVE"
       VERDICT_WHY="a surviving node was unreachable or rejected authentication during the measurement, so no statement about the data is possible" ;;
    *) VERDICT="INCONCLUSIVE"
       VERDICT_WHY="the cache harness exited $rc — see evidence/during/cache-after.txt" ;;
  esac
}

dg_stop_all() {
  local i node
  declare -p DG_NODES >/dev/null 2>&1 || return 0
  for (( i=0; i<${#DG_NODES[@]}; i++ )); do
    node="${DG_NODES[$i]}"
    [[ -f "$PKG/nodes/$node.pid" ]] && kill_recorded_pid "$PKG/nodes/$node.pid" "infinispan.node.name=$node" TERM
  done
  for (( i=0; i<${#DG_NODES[@]}; i++ )); do
    wait_for_port_closed "$WS_BIND" "${DG_PORTS[$i]}" 30 || true
  done
  return 0
}

dg_collect_logs() {
  local i node
  for (( i=0; i<${#DG_NODES[@]}; i++ )); do
    node="${DG_NODES[$i]}"
    [[ -f "$PKG/nodes/$node/log/server.log" ]] && cp "$PKG/nodes/$node/log/server.log" "$PKG/logs/$node-server.log"
    [[ -f "$PKG/nodes/$node/conf/infinispan.xml" ]] && cp "$PKG/nodes/$node/conf/infinispan.xml" "$PKG/config/$node-infinispan.xml"
  done
  grep -hE 'ISPN0000|ISPN0040|WARN|ERROR' "$PKG"/logs/*-server.log 2>/dev/null \
    | head -300 >"$PKG/evidence/after/log-highlights.txt" || true
  return 0
}
