#!/usr/bin/env bash
# eap.sh — JBoss EAP reproduction driver (shared by the eap7 and eap8 workspaces).
#
# The two workspaces differ only in workspace.env: install location, major version, port
# block, and the Jakarta namespace the test app is built against. Everything below is
# version-agnostic and reads what it needs from the installation in front of it.

# --- installation discovery --------------------------------------------------

# The version an install reports about itself. version.txt is the banner and outranks the
# directory name — a patched 7.4.0 tree reports 7.4.23.GA — so the basename is only the
# fallback for trees that ship no version.txt.
eap_version_string() {
  local home="$1" v=""
  if [[ -f "$home/version.txt" ]]; then
    v="$(head -1 "$home/version.txt" | tr -d '\r' || true)"
  fi
  [[ -z "$v" ]] && v="$(basename "$home")"
  printf '%s' "$v"
}

# First dotted numeric version in a string, empty when there is none.
#   "…Platform - Version 7.4.23.GA" -> 7.4.23      "8.2.0 (GA)" -> 8.2.0
eap_version_num() { grep -oE '[0-9]+(\.[0-9]+)*' <<<"$1" | head -1 || true; }

# True (0) only when two versions disagree on a component BOTH of them state.
#   8.2   vs 8.1     -> differ
#   7.4.0 vs 7.4.23  -> differ (both state a micro, and it is not the same one)
#   8.1.0 vs 8.1     -> do NOT differ; the banner simply does not state a micro, and
#                       inventing a difference here would train everyone to skip the
#                       deviation list, which is the one list that has to stay worth reading.
eap_version_differs() {
  local i n
  local -a x y
  IFS=. read -r -a x <<<"$1"
  IFS=. read -r -a y <<<"$2"
  n=${#x[@]}; (( ${#y[@]} < n )) && n=${#y[@]}
  for (( i=0; i<n; i++ )); do
    [[ "${x[$i]}" == "${y[$i]}" ]] || return 0
  done
  return 1
}

eap_discover() {
  local cand="" g sub c mm
  local -a cands=()

  if [[ -n "${EAP_HOME:-}" ]]; then
    cands=("$EAP_HOME")
  else
    # workspace.env gives the globs; collect EVERY tree that holds bin/standalone.sh rather
    # than stopping at the first. Bash expands a glob in sorted order, so with 8.1.0 and
    # 8.2.0 both installed the first match is 8.1 — and an 8.2 case was being answered by an
    # 8.1 run, which the major guard below cannot see. Selection happens against the case.
    for g in $WS_INSTALL_GLOB; do
      if [[ -x "$g/bin/standalone.sh" ]]; then cands+=("$g"); continue; fi
      # one level down: vendors ship jboss-eap-7.4.0/jboss-eap-7.4/
      for sub in "$g"/*/; do
        if [[ -x "${sub%/}/bin/standalone.sh" ]]; then cands+=("${sub%/}"); fi
      done
    done
  fi

  (( ${#cands[@]} > 0 )) || blocked \
"no $WS_PRODUCT_LABEL installation found.
       Looked under: $WS_INSTALL_GLOB
       Set it explicitly:   EAP_HOME=/path/to/jboss-eap-$WS_MAJOR.x ./run.sh"

  # THE CASE IS AUTHORITATIVE. When it names a version, the install whose own banner agrees
  # with it wins. Only when the case names none, or none of them agrees, does the newest win
  # — never simply whichever one the glob happened to produce first.
  local want_ver=""
  [[ -n "${CASE_VERSION:-}" ]] && want_ver="$(eap_version_num "$CASE_VERSION")"

  if [[ -n "$want_ver" ]]; then
    for c in "${cands[@]}"; do
      mm="$(eap_version_num "$(eap_version_string "$c")")"
      if [[ -n "$mm" ]] && ! eap_version_differs "$want_ver" "$mm"; then cand="$c"; break; fi
    done
  fi

  if [[ -z "$cand" ]]; then
    local newest="" newest_mm="0"
    for c in "${cands[@]}"; do
      mm="$(eap_version_num "$(eap_version_string "$c")")"
      [[ -z "$mm" ]] && mm="0"
      if [[ "$(printf '%s\n%s\n' "$newest_mm" "$mm" | sort -V | tail -1)" == "$mm" ]]; then
        newest="$c"; newest_mm="$mm"
      fi
    done
    cand="$newest"
  fi

  [[ -n "$cand" && -x "$cand/bin/standalone.sh" ]] || blocked \
"no usable $WS_PRODUCT_LABEL installation among: ${cands[*]}
       Set one explicitly:   EAP_HOME=/path/to/jboss-eap-$WS_MAJOR.x ./run.sh"

  EAP_HOME="$(cd "$cand" && pwd)"

  EAP_VERSION="UNKNOWN"
  if [[ -f "$EAP_HOME/version.txt" ]]; then
    EAP_VERSION="$(head -1 "$EAP_HOME/version.txt" | tr -d '\r' || true)"
  elif [[ -f "$EAP_HOME/JBossEULA.txt" ]]; then
    EAP_VERSION="$(basename "$EAP_HOME")"
  fi
  local lab_ver="$EAP_VERSION"
  [[ "$lab_ver" == "UNKNOWN" ]] && lab_ver="$(basename "$EAP_HOME")"

  # Confirm the install really is the major this workspace runs.
  local found_major
  found_major="$(grep -oE '[0-9]+\.[0-9]+' <<<"$EAP_VERSION $(basename "$EAP_HOME")" | head -1 | cut -d. -f1 || true)"
  if [[ -n "$found_major" && "$found_major" != "$WS_MAJOR" ]]; then
    die "installation at $EAP_HOME looks like EAP $found_major, but this workspace runs EAP $WS_MAJOR.
       Use the other workspace, or point EAP_HOME at an EAP $WS_MAJOR.x install."
  fi

  export EAP_HOME EAP_VERSION
  ok "EAP_HOME=$EAP_HOME"
  info "version banner: $EAP_VERSION"
  if (( ${#cands[@]} > 1 )); then
    info "chose it from ${#cands[@]} installs: ${cands[*]}"
  fi

  # Minor/micro mismatch. The major guard cannot see it, and a verdict about 8.1 is not a
  # verdict about 8.2 in either direction — so it is recorded rather than assumed harmless.
  local have_ver; have_ver="$(eap_version_num "$lab_ver")"
  if [[ -n "$want_ver" && -n "$have_ver" ]] && eap_version_differs "$want_ver" "$have_ver"; then
    warn "customer runs $CASE_VERSION, the lab has $have_ver — recorded as a deviation"
    if (( ${#cands[@]} > 1 )); then
      warn "no install here reports $want_ver; point at one with EAP_HOME=... ./run.sh"
    fi
    DEVIATIONS+=("EAP version: customer=$CASE_VERSION reproducer=$have_ver. Behaviour changes between minor and micro releases, so this verdict is about $have_ver and does not transfer to $CASE_VERSION without a run on that build.")
  fi
}

# The JDK question is version-specific and unsafe to recall, so the requirement comes from
# workspace.env (which cites its source) and is verified against what is installed.
eap_resolve_jdk() {
  local want="${CASE_JDK_MAJOR:-}"
  [[ -z "$want" ]] && want="$(grep -oE '[0-9]+' <<<"${CASE_JDK:-}" | head -1 || true)"
  [[ -z "$want" ]] && want="$WS_DEFAULT_JDK"

  if ! grep -qE "(^| )$want( |$)" <<<"$WS_SUPPORTED_JDKS"; then
    warn "JDK $want is not in this workspace's supported list ($WS_SUPPORTED_JDKS)."
    warn "Source: $WS_JDK_SOURCE"
    warn "Continuing, because the customer's JDK is the point of the reproduction —"
    warn "but a boot failure here may be the JDK, not the customer's issue."
  fi

  if JAVA_HOME="$(resolve_jdk "$want")"; then
    ok "JDK $want at $JAVA_HOME"
  else
    warn "no JDK $want installed. Available:"; list_jdks >&2
    # The JDK the case names is a stated fact about the customer, the same as the JGroups
    # stack, and quietly running on a different one produces a verdict about a system nobody
    # asked about. This used to substitute silently with only a deviation line to show for it;
    # the JVM workspace has always stopped instead, and there is no reason the rule should
    # differ by product. --allow-jdk-substitute is the deliberate opt-out.
    if (( ${ALLOW_JDK_SUBSTITUTE:-0} == 0 )); then
      blocked "the case names JDK $want and it is not installed on this host.
       Install it and re-run — unpacking a build under ~/jdks/ is enough, no root needed:
           mkdir -p ~/jdks && tar -C ~/jdks -xf <jdk-$want-linux-x64.tar.gz>
       Or accept a substitute and have it recorded as a deviation:
           ./run.sh --allow-jdk-substitute"
    fi
    local alt
    for alt in $WS_SUPPORTED_JDKS; do
      if JAVA_HOME="$(resolve_jdk "$alt")"; then
        warn "falling back to JDK $alt — RECORDED AS A DEVIATION from the customer's JDK $want"
        DEVIATIONS+=("JDK: customer=$want reproducer=$alt (--allow-jdk-substitute; JDK $want not installed, and it may mask or cause JDK-specific behaviour)")
        break
      fi
      JAVA_HOME=""
    done
    [[ -n "${JAVA_HOME:-}" ]] || blocked "no supported JDK ($WS_SUPPORTED_JDKS) found for $WS_PRODUCT_LABEL."
  fi
  export JAVA_HOME
}

# --- port plan ---------------------------------------------------------------
# Offsets come from workspace.env so eap7 and eap8 can run at the same time.
eap_plan_ports() {
  local n="$1" i off
  EAP_OFFSETS=(); EAP_HTTP=(); EAP_MGMT=(); EAP_JGROUPS=(); EAP_NODES=()
  for (( i=0; i<n; i++ )); do
    off=$(( WS_OFFSET_BASE + i * 100 ))
    EAP_OFFSETS+=("$off")
    EAP_HTTP+=($(( 8080 + off )))
    EAP_MGMT+=($(( 9990 + off )))
    EAP_JGROUPS+=($(( 7600 + off )))
    EAP_NODES+=("node$((i+1))")
  done
  export EAP_OFFSETS EAP_HTTP EAP_MGMT EAP_JGROUPS EAP_NODES
  info "port plan: http=${EAP_HTTP[*]} mgmt=${EAP_MGMT[*]} jgroups=${EAP_JGROUPS[*]}"
  assert_ports_free "${EAP_HTTP[@]}" "${EAP_MGMT[@]}" "${EAP_JGROUPS[@]}"
}

# --- per-node base directories ----------------------------------------------
# A port offset alone is NOT isolation: instances then share data/, tmp/, log/ and the
# deployment markers under the single standalone/ tree, and corrupt each other in ways that
# look exactly like the clustering bug being investigated.
eap_seed_nodes() {
  local n="$1" i node dir
  step "Seeding $n isolated node directories"
  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"
    dir="$PKG/nodes/$node"
    assert_in_pkg "$dir"
    rm -rf "$dir"
    mkdir -p "$dir/configuration" "$dir/deployments" "$dir/data" "$dir/log" "$dir/tmp"
    cp -r "$EAP_HOME/standalone/configuration/." "$dir/configuration/"
    info "$node -> $dir"
  done
}

# Customer-supplied configuration wins over the shipped default: reproducing with the stock
# file reproduces the stock file's behaviour, not the customer's.
eap_apply_customer_config() {
  local src n i node applied=0
  for src in "$WS_DIR/input/configs"/*.xml; do
    [[ -f "$src" ]] || continue
    n="$(basename "$src")"
    case "$n" in
      standalone*.xml)
        for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
          node="${EAP_NODES[$i]}"
          cp "$src" "$PKG/nodes/$node/configuration/$SERVER_CONFIG"
        done
        cp "$src" "$PKG/config/customer-$n"
        ok "applied customer $n as $SERVER_CONFIG on every node"
        DEVIATIONS+=("server config: customer's $n used verbatim (stock $SERVER_CONFIG replaced)")
        applied=1 ;;
      *)
        cp "$src" "$PKG/config/customer-$n"
        info "copied $n into the package (not auto-applied: unrecognised config type)" ;;
    esac
  done
  CUSTOMER_CONFIG_APPLIED="$applied"
  if (( applied == 0 )); then
    info "no customer standalone*.xml in input/configs — using shipped $SERVER_CONFIG"
    DEVIATIONS+=("server config: NO customer config supplied; shipped $SERVER_CONFIG used (fidelity gap)")
  fi
  export CUSTOMER_CONFIG_APPLIED
}

# --- stack selection ---------------------------------------------------------
# Decide which JGroups stack this run uses, and be explicit about why.
#
# THE CASE IS AUTHORITATIVE. If it names a stack, that is the stack, in every scenario. This
# used to hold only for cluster-formation cases and normalise everything else to tcp/TCPPING,
# on the theory that the discovery protocol was a lab detail whenever it was not the headline
# complaint. Two things were wrong with that. It answers a question nobody asked — a session
# case on udp is a different system from the same case on tcp, and replication failures that
# only appear under multicast are exactly the ones a support engineer is chasing. And the
# premise was false: multicast between processes on one host works fine (the kernel delivers
# it locally), so there was never a lab defect needing to be normalised away.
#
# tcp/TCPPING remains the default when the case says nothing, because an unnamed stack is a
# gap in the case rather than a statement, and TCPPING has no dependency on the network. That
# default is labelled INFERRED so nobody mistakes it for something the customer said.
eap_select_stack() {
  local want; want="$(detect_stack)"
  if [[ -n "$want" ]]; then
    JG_STACK="$want"
    JG_STACK_SRC="named in the case — used as stated, no override"
    if [[ "$SCENARIO" != "cluster-formation" ]]; then
      # Worth recording: on a '$want' stack a scenario like session-failover can fail for a
      # discovery reason that has nothing to do with sessions, and the reader needs to know
      # the stack was the customer's choice and not the lab's.
      DEVIATIONS+=("JGroups stack: '$want' as named in the case, kept for scenario '$SCENARIO' rather than normalised to tcp/TCPPING. A discovery problem on this stack will therefore surface inside this scenario's measurement.")
    fi
  else
    JG_STACK="tcp"
    JG_STACK_SRC="INFERRED — the case names no stack; tcp/TCPPING is used because it depends on nothing about the network"
    DEVIATIONS+=("JGroups stack: NOT STATED in the case; run used 'tcp' with TCPPING. Add 'udp stack' or 'tcp stack' to case.txt to pin it.")
  fi
  export JG_STACK JG_STACK_SRC
  info "JGroups stack: $JG_STACK ($JG_STACK_SRC)"
}

# Run on the udp stack exactly as shipped, and verify that is what will happen.
#
# There is nothing to overlay here — the point is the absence of an overlay — but the
# verification still matters: EAP 8.1 hardcodes the 'ee' channel's stack with no expression,
# so whether -Djboss.default.jgroups.stack is honoured has to be read out of the XML rather
# than assumed in either direction.
eap_apply_udp() {
  local n="${#EAP_NODES[@]}" i node cfg cli="$PKG/config/udp-stack.cli" out rc=0
  step "Running on the 'udp' stack as the case describes (no discovery overlay)"
  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"
    cat >"$cli" <<EOF
embed-server --server-config=$SERVER_CONFIG --std-out=discard
if (outcome == success) of /subsystem=jgroups/channel=ee:read-resource
  /subsystem=jgroups/channel=ee:write-attribute(name=stack, value=udp)
end-if
stop-embedded-server
EOF
    out="$(JAVA_HOME="$JAVA_HOME" JBOSS_HOME="$EAP_HOME" \
           "$EAP_HOME/bin/jboss-cli.sh" \
           -Djboss.server.base.dir="$PKG/nodes/$node" \
           --file="$cli" 2>&1)" || rc=$?
    printf '[%s] jboss-cli udp-stack %s (exit %s)\n%s\n\n' "$(ts)" "$node" "$rc" "$out" >>"$COMMANDS_LOG"
    cfg="$PKG/nodes/$node/configuration/$SERVER_CONFIG"
    grep -qE '<channel name="ee"[^>]*stack="udp"' "$cfg" \
      || blocked "the 'ee' channel in $cfg is not on the udp stack.
       The run would then measure a stack the case does not describe."
  done
  ok "'ee' channel pinned to the udp stack on all $n nodes — discovery is MPING/multicast"
  DEVIATIONS+=("discovery: left as the customer describes (udp/multicast). NOT overlaid with TCPPING, because the udp stack is the subject of this case.")
  return 0
}

# --- clustering overlay ------------------------------------------------------
# Multicast discovery does not work between processes on one host: the loopback interface
# carries no MULTICAST flag, so every node forms a cluster of one and every later
# "replication failure" is an artifact of the lab. TCPPING with explicit initial_hosts is
# the only discovery that is reliable here.
eap_apply_tcpping() {
  local n="${#EAP_NODES[@]}" i hosts="" cli="$PKG/config/tcpping.cli" node out rc=0
  # initial_hosts must name the address JGroups is actually bound to. When a rung of the
  # remediation ladder has moved the private binding off loopback, a list built from WS_BIND
  # points every node at a socket nothing is listening on, and TCPPING gets blamed for it.
  local jg_bind="${EAP_PRIVATE_BIND:-$WS_BIND}"
  for (( i=0; i<n; i++ )); do
    hosts+="${hosts:+,}$jg_bind[${EAP_JGROUPS[$i]}]"
  done
  step "Overlaying TCPPING discovery (initial_hosts=$hosts)"

  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"
    cat >"$cli" <<EOF
embed-server --server-config=$SERVER_CONFIG --std-out=discard
if (outcome == success) of /subsystem=jgroups/stack=tcp/protocol=MPING:read-resource
  /subsystem=jgroups/stack=tcp/protocol=MPING:remove()
end-if
if (outcome == success) of /subsystem=jgroups/stack=tcp/protocol=TCPPING:read-resource
  /subsystem=jgroups/stack=tcp/protocol=TCPPING:remove()
end-if
/subsystem=jgroups/stack=tcp/protocol=TCPPING:add(add-index=0, properties={initial_hosts="$hosts", port_range=0})
if (outcome == success) of /subsystem=jgroups/channel=ee:read-resource
  /subsystem=jgroups/channel=ee:write-attribute(name=stack, value=tcp)
end-if
stop-embedded-server
EOF
    out="$(JAVA_HOME="$JAVA_HOME" JBOSS_HOME="$EAP_HOME" \
           "$EAP_HOME/bin/jboss-cli.sh" \
           -Djboss.server.base.dir="$PKG/nodes/$node" \
           --file="$cli" 2>&1)" || rc=$?
    printf '[%s] jboss-cli tcpping %s (exit %s)\n%s\n\n' "$(ts)" "$node" "$rc" "$out" >>"$COMMANDS_LOG"
    if (( rc != 0 )) || grep -qi 'failed\|WFLYCTL' <<<"$out"; then
      printf '%s\n' "$out" | tail -20 >&2
      blocked "could not apply TCPPING discovery to $node.
       Without it each node forms a cluster of one on loopback and every clustering
       verdict from this run would be a lab artifact, not a product finding.
       Full CLI output: $COMMANDS_LOG"
    fi
    # EAP 8.1 ships <channel name="ee" stack="udp"/> with no expression around the stack
    # name, so -Djboss.default.jgroups.stack is silently ignored there and the TCPPING the
    # run just wrote into the tcp stack would never be used. Read the result back rather
    # than assuming the CLI did what was asked.
    local cfg="$PKG/nodes/$node/configuration/$SERVER_CONFIG"
    grep -q 'TCPPING' "$cfg" \
      || blocked "TCPPING is not present in $cfg after the CLI reported success."
    grep -qE '<channel name="ee"[^>]*stack="tcp"' "$cfg" \
      || blocked "the 'ee' channel in $cfg is not on the tcp stack after the overlay.
       It would run on udp/multicast instead, and the discovery this run reports would not
       be the discovery it used."
  done
  ok "TCPPING applied and the 'ee' channel switched to the tcp stack on all $n nodes"
  DEVIATIONS+=("discovery: TCPPING(initial_hosts=$hosts) on the tcp stack instead of the customer's discovery protocol. This is the lab's default for cases that are not ABOUT discovery, so that a clustering verdict does not rest on whether multicast happens to work here. Cases that name the udp stack keep it — see eap_select_stack.")
}

# Read something out of a running server. The management API is the only authority for
# runtime state: EAP 8 logs a cluster view once, at connect time, and never logs the view it
# ends up with, so grepping server.log there reports a cluster of one that does not exist.
eap_cli() {
  local port="$1" cmd="$2"
  JAVA_HOME="$JAVA_HOME" JBOSS_HOME="$EAP_HOME" "$EAP_HOME/bin/jboss-cli.sh" \
    --connect --controller="$WS_BIND:$port" --command="$cmd" 2>&1
}

# The "result" => "..." payload of a successful :read-attribute.
eap_cli_result() {
  sed -nE 's/.*"result"[[:space:]]*=>[[:space:]]*"(.*)".*/\1/p' <<<"$1" | head -1
}

# What one node currently believes the cluster is. Echoes "<members>|<stack>|<source>|<view>".
#
# Two sources, because neither covers both majors on its own: the management API reports
# channel=ee's live view on EAP 7 but leaves every channel runtime attribute undefined on
# EAP 8.1 even with statistics enabled; the log carries a running view on EAP 7 (ISPN000094)
# while EAP 8 logs WFLYCLJG0033 exactly once, at connect, when the node is still alone — so a
# log-only reading fails a healthy EAP 8 cluster. What does move on EAP 8 is the Infinispan
# rebalance line, which names the members.
#
# It never dies and never blocks a run. Whether a view of one is a fault or the finding is
# the caller's decision, and for a "cluster will not form" case it is the finding.
eap_view_of_node() {
  local i="$1" timeout="${2:-60}" want="${3:-0}"
  local node="${EAP_NODES[$i]}" log view="" members=0 out="" stack="" waited=0 src=""
  log="$PKG/nodes/$node/log/server.log"
  [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
  while :; do
    out="$(eap_cli "${EAP_MGMT[$i]}" '/subsystem=jgroups/channel=ee:read-attribute(name=view)' 2>/dev/null || true)"
    view="$(eap_cli_result "$out")"
    src="management API (jgroups channel=ee view)"
    if [[ -z "$view" ]]; then
      view="$(grep -hE 'ISPN000094|ISPN100002: Starting rebalance with members|WFLYCLJG0033' "$log" 2>/dev/null | tail -1 || true)"
      src="$(basename "$log")"
    fi
    if [[ -n "$view" ]]; then members="$(view_size "$view")"; else members=0; fi
    (( want > 0 && members >= want )) && break
    (( waited >= timeout )) && break
    sleep 5; waited=$(( waited + 5 ))
  done
  stack="$(eap_cli_result "$(eap_cli "${EAP_MGMT[$i]}" '/subsystem=jgroups/channel=ee:read-attribute(name=stack)' 2>/dev/null || true)")"
  printf '%s|%s|%s|%s' "$members" "${stack:-UNKNOWN}" "${src:-none}" "${view:-NONE}"
}

# Poll every node and write the per-node detail to $1. Sets CLUSTER_MIN_MEMBERS to the
# smallest view held by any node — the honest number, because a cluster is only formed when
# the LAST node agrees it is. Returns 0 only when every node sees every node.
eap_cluster_probe() {
  local out="$1" timeout="${2:-120}" n="${#EAP_NODES[@]}" i r m stack src view min=-1
  : >"$out"
  for (( i=0; i<n; i++ )); do
    r="$(eap_view_of_node "$i" "$timeout" "$n")"
    m="${r%%|*}";      r="${r#*|}"
    stack="${r%%|*}";  r="${r#*|}"
    src="${r%%|*}";    view="${r#*|}"
    printf '%-8s members=%s/%s stack=%-7s source=%s\n         %s\n' \
      "${EAP_NODES[$i]}" "$m" "$n" "$stack" "$src" "$view" >>"$out"
    if (( min < 0 || m < min )); then min="$m"; fi
    CLUSTER_STACK_SEEN="$stack"
  done
  CLUSTER_MIN_MEMBERS="$min"
  export CLUSTER_MIN_MEMBERS CLUSTER_STACK_SEEN
  if (( min >= n )); then return 0; else return 1; fi
}

# Stop every node and file this attempt's logs under a label, so each rung of the
# remediation ladder keeps its own evidence instead of overwriting the previous one.
# Configuration changes go BETWEEN this and eap_cycle_end: the CLI overlay needs an
# embedded server, which cannot run while the real one holds the same base directory.
eap_cycle_begin() {
  local label="$1" i node slug
  slug="$(slugify "$label")"
  step "Stopping all nodes — preparing attempt: $label"
  eap_stop_all
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    node="${EAP_NODES[$i]}"
    [[ -f "$PKG/nodes/$node/log/server.log" ]] \
      && mv "$PKG/nodes/$node/log/server.log" "$PKG/logs/$node-server-$slug.log"
    [[ -f "$PKG/logs/$node-console.log" ]] \
      && cp "$PKG/logs/$node-console.log" "$PKG/logs/$node-console-$slug.log"
    rm -f "$PKG/nodes/$node.pid"
  done
  return 0
}

# Start them again and wait for a real boot. Returns non-zero if any node fails to come
# back — the caller must treat that as an attempt that never got far enough to judge, not
# as a cluster that failed to form. Conflating the two invents a finding.
eap_cycle_end() {
  local i node log
  eap_start_nodes
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    node="${EAP_NODES[$i]}"
    wait_for_port "$WS_BIND" "${EAP_HTTP[$i]}" 240 || { warn "$node did not reopen its http port"; return 1; }
    log="$PKG/nodes/$node/log/server.log"
    [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
    wait_for_log "$log" 'WFLYSRV0025|started in' 240 || { warn "$node did not complete boot"; return 1; }
  done
  return 0
}

# --- application -------------------------------------------------------------
eap_build_app() {
  local blueprint="$1"
  step "Building test application ($blueprint, EAP $WS_MAJOR / ${WS_NS} namespace)"

  # A customer WAR is higher fidelity than anything generated here.
  local cust
  cust="$(ls "$WS_DIR/input/attachments"/*.war "$WS_DIR/input/attachments"/*.ear 2>/dev/null | head -1 || true)"
  if [[ -n "$cust" ]]; then
    APP_FILE="$PKG/app/$(basename "$cust")"
    cp "$cust" "$APP_FILE"
    APP_CONTEXT="$(basename "${cust%.*}")"
    CUSTOMER_APP_APPLIED=1
    ok "using the customer's own artifact: $(basename "$cust")"
    DEVIATIONS+=("application: customer artifact $(basename "$cust") used (highest fidelity)")
    export APP_FILE APP_CONTEXT CUSTOMER_APP_APPLIED
    return 0
  fi

  have mvn || blocked "maven (mvn) is not installed — cannot build the test application.
       Install it (dnf install maven) or drop a prebuilt WAR in input/attachments/."

  local build="$PKG/app/src"
  mkdir -p "$build"
  TARGET_MAJOR="$WS_MAJOR" APP_NAME=repro JDK_TARGET="$(jdk_major "$JAVA_HOME")" \
    "$TEMPLATES_DIR/apps/prepare-app.sh" "$blueprint" "$build" \
    >>"$COMMANDS_LOG" 2>&1 \
    || { tail -30 "$COMMANDS_LOG" >&2; blocked "test application build failed — see $COMMANDS_LOG"; }

  APP_FILE="$(ls "$build"/target/*.war 2>/dev/null | head -1 || true)"
  [[ -n "$APP_FILE" ]] || blocked "build produced no WAR under $build/target"
  APP_CONTEXT="repro"
  CUSTOMER_APP_APPLIED=0
  ok "built $(basename "$APP_FILE") ($(human_size "$(stat -c%s "$APP_FILE")"))"
  export APP_FILE APP_CONTEXT CUSTOMER_APP_APPLIED
}

eap_deploy() {
  local i node
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    node="${EAP_NODES[$i]}"
    cp "$APP_FILE" "$PKG/nodes/$node/deployments/"
  done
  info "deployment dropped on all nodes: $(basename "$APP_FILE")"
}

# --- start -------------------------------------------------------------------
eap_start_nodes() {
  local n="${#EAP_NODES[@]}" i node off log
  step "Starting $n node(s)"
  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"; off="${EAP_OFFSETS[$i]}"
    log="$PKG/logs/$node-console.log"
    : >"$log"
    # The stack is a variable, not a constant: on a "cluster will not form on udp" case the
    # stack under test is the customer's, and hardcoding tcp here would silently fix it.
    JAVA_HOME="$JAVA_HOME" nohup "$EAP_HOME/bin/standalone.sh" \
      -c "$SERVER_CONFIG" \
      -Djboss.server.base.dir="$PKG/nodes/$node" \
      -Djboss.socket.binding.port-offset="$off" \
      -Djboss.node.name="$node" \
      -Djboss.default.jgroups.stack="${JG_STACK:-tcp}" \
      -b "$WS_BIND" -bmanagement "$WS_BIND" -bprivate "${EAP_PRIVATE_BIND:-$WS_BIND}" \
      ${EAP_EXTRA_PROPS[@]+"${EAP_EXTRA_PROPS[@]}"} \
      >>"$log" 2>&1 &
    printf '[%s] START %s offset=%s http=%s stack=%s private=%s extra=%s\n' \
      "$(ts)" "$node" "$off" "${EAP_HTTP[$i]}" "${JG_STACK:-tcp}" "${EAP_PRIVATE_BIND:-$WS_BIND}" \
      "${EAP_EXTRA_PROPS[*]:-none}" >>"$COMMANDS_LOG"
    info "$node starting (offset $off, http ${EAP_HTTP[$i]}, stack ${JG_STACK:-tcp}) -> $log"
  done

  # Record the real java PIDs, not standalone.sh's. Killing the wrapper leaves an orphaned
  # JVM that keeps serving traffic — the failover then never happens and the run reports
  # "not reproduced" about a node that never went away.
  sleep 5
  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"
    local pid=""
    local w=0
    while (( w < 30 )); do
      pid="$(java_pid_for "jboss.node.name=$node" || true)"
      [[ -n "$pid" ]] && break
      sleep 1; ((w++))
    done
    [[ -n "$pid" ]] || blocked "$node did not produce a JVM process — see $PKG/logs/$node-console.log"
    echo "$pid" >"$PKG/nodes/$node.pid"
    info "$node jvm pid $pid"
  done
}

# --- boot failure diagnosis and one automatic correction ----------------------
# Why a node's JVM is gone, in the product's own words.
eap_boot_failure_reason() {
  local node="$1" log="$PKG/logs/$node-console.log" r=""
  [[ -f "$log" ]] || { printf '(no console log at %s)' "$log"; return 0; }
  r="$(grep -m1 -E 'UnsupportedClassVersionError|Address already in use|WFLYCTL0085|WFLYSRV0073|Unrecognized option|Could not create the Java Virtual Machine|OutOfMemoryError' "$log" 2>/dev/null || true)"
  [[ -z "$r" ]] && r="$(grep -m1 -E 'FATAL|ERROR' "$log" 2>/dev/null || true)"
  printf '%s' "${r:-(no error line in the console log)}"
}

# Which Java the installation's own class files demand. The JVM states it exactly — "class
# file version 61.0" — and the mapping to a release is arithmetic, not recall: 61-44 = 17.
# Nothing is inferred from the product name or the directory it sits in.
eap_required_jdk_from_log() {
  local node="$1" log="$PKG/logs/$node-console.log" v=""
  [[ -f "$log" ]] || return 0
  v="$(grep -m1 -oE 'class file version [0-9]+' "$log" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [[ -n "$v" ]] && printf '%s' $(( v - 44 ))
  return 0
}

# Wait for a node's http port, but stop the moment its JVM exits.
#
# Polling a port for four minutes after the process that would open it has died spends four
# minutes to learn nothing, and then reports "never opened its port" — true, and useless,
# when the real reason has been sitting in the console log the whole time.
eap_wait_port_or_death() {
  local i="$1" timeout="${2:-240}" node="${EAP_NODES[$i]}" pid waited=0
  pid="$(cat "$PKG/nodes/$node.pid" 2>/dev/null || true)"
  NODE_DIED=""
  while (( waited < timeout )); do
    port_open "$WS_BIND" "${EAP_HTTP[$i]}" && return 0
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      NODE_DIED="$node"; export NODE_DIED; return 1
    fi
    sleep 2; waited=$(( waited + 2 ))
  done
  export NODE_DIED
  return 1
}

# One automatic retry when the nodes died for a reason the harness can correct itself.
#
# Deliberately narrow. The only correction made here is the JDK, because that failure has an
# unambiguous signature AND states its own fix: the class file version in the message says
# which Java is required, so the new JDK is read out of the error rather than guessed. A
# retry loop over causes that do not name their own fix would just be a slower way of
# guessing, and the run would stop being evidence.
eap_autofix_boot() {
  local n="${#EAP_NODES[@]}" i pid alive=0 need newhome alt
  sleep 5
  for (( i=0; i<n; i++ )); do
    pid="$(cat "$PKG/nodes/${EAP_NODES[$i]}.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive=$(( alive + 1 )); fi
  done
  (( alive == n )) && return 0

  warn "$(( n - alive ))/$n JVM(s) exited during boot"
  warn "reason: $(eap_boot_failure_reason "${EAP_NODES[0]}")"

  need="$(eap_required_jdk_from_log "${EAP_NODES[0]}")"
  [[ -n "$need" ]] || return 0      # not a JDK problem; let the gate report it

  newhome="$(resolve_jdk "$need" 2>/dev/null || true)"
  if [[ -z "$newhome" ]]; then
    for alt in $WS_SUPPORTED_JDKS; do
      (( alt < need )) && continue
      newhome="$(resolve_jdk "$alt" 2>/dev/null || true)"
      if [[ -n "$newhome" ]]; then need="$alt"; break; fi
    done
  fi
  [[ -n "$newhome" ]] || blocked "this $WS_PRODUCT_LABEL installation needs Java $need or newer and none is installed.
       Reason from the server's own log: $(eap_boot_failure_reason "${EAP_NODES[0]}")
       Install a JDK $need and re-run."
  [[ "$newhome" == "$JAVA_HOME" ]] && return 0

  step "Auto-correcting the JDK — this installation requires Java $need — and retrying"
  DEVIATIONS+=("JDK: the run started on $(jdk_major "$JAVA_HOME") and every node died with UnsupportedClassVersionError; auto-corrected to Java $need at $newhome. The customer's stated JDK was ${CASE_JDK:-NOT PROVIDED}.")
  JAVA_HOME="$newhome"; export JAVA_HOME
  eap_cycle_begin "jdk$need-retry"
  eap_cycle_end || blocked "nodes still would not boot on Java $need.
       Reason: $(eap_boot_failure_reason "${EAP_NODES[0]}")"
  ok "all nodes booted after the JDK was corrected to Java $need"
  return 0
}

# --- the five startup gates --------------------------------------------------
# Every one of these has produced a false "reproduction" when skipped. They are not
# ceremony; they are the difference between a product finding and a lab artifact.
eap_gates() {
  local n="${#EAP_NODES[@]}" i node log

  step "Gate 1/5 — ports listening"
  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"
    if eap_wait_port_or_death "$i" 240; then continue; fi
    if [[ -n "${NODE_DIED:-}" ]]; then
      blocked "$node's JVM exited during boot — it never got as far as opening a port.
       Its own log says: $(eap_boot_failure_reason "$node")
       Full log: $PKG/logs/$node-console.log"
    fi
    blocked "$node never opened http port ${EAP_HTTP[$i]}, though its JVM is still alive.
       Last error in its log: $(eap_boot_failure_reason "$node")
       Full log: $PKG/logs/$node-console.log"
  done
  ok "all ${n} http ports listening"

  step "Gate 2/5 — clean boot"
  for (( i=0; i<n; i++ )); do
    node="${EAP_NODES[$i]}"; log="$PKG/nodes/$node/log/server.log"
    [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
    wait_for_log "$log" 'WFLYSRV0025|started in' 240 \
      || blocked "$node never reported a completed boot (see $log)"
    local errs
    errs="$(count_matches "$log" 'WFLYSRV0026|started \(with errors\)')"
    if [[ "$errs" != "0" ]]; then
      warn "$node started WITH ERRORS — captured, and treated as a finding, not ignored"
      grep -E 'ERROR|WFLYSRV0026' "$log" | head -20 >"$PKG/evidence/before/$node-boot-errors.txt" || true
      BOOT_ERRORS=$(( BOOT_ERRORS + 1 ))
    fi
  done
  ok "boot complete on all nodes (${BOOT_ERRORS} with errors)"

  step "Gate 3/5 — cluster formed (every node sees every node)"
  if (( n == 1 )); then
    info "single node — clustering gate not applicable"
  elif eap_cluster_probe "$PKG/evidence/before/cluster-views.txt" 180; then
    cat "$PKG/evidence/before/cluster-views.txt"
    ok "cluster of $n formed and visible from every node (stack=${CLUSTER_STACK_SEEN:-?})"
  else
    cat "$PKG/evidence/before/cluster-views.txt"
    # For a "the cluster does not form" case this IS the symptom, and blocking here would be
    # refusing to reproduce the very thing under investigation — the same reasoning that
    # makes gate 4 measure rather than block on a deployment case.
    if [[ "${GATE3_MODE:-block}" == "measure" ]]; then
      warn "smallest view is ${CLUSTER_MIN_MEMBERS:-0}/$n — recorded, not blocking: cluster formation is what this case is about"
    else
      blocked "the cluster did not fully form: the smallest view any node holds is ${CLUSTER_MIN_MEMBERS:-0} of $n.
       Detail: $PKG/evidence/before/cluster-views.txt
       Stopping here: a partial cluster produces exactly the symptom under investigation, so
       continuing would fabricate a reproduction. If the cluster NOT forming is the customer's
       actual complaint, re-run with:  ./run.sh --scenario cluster-formation"
    fi
  fi

  step "Gate 4/5 — application endpoint answers"
  # Deployment status is NOT proof. A javax WAR deploys cleanly on EAP 8 and reports
  # healthy while every servlet 404s, because the annotations were never scanned.
  #
  # For a deployment case that 404 is the symptom itself, so the gate measures instead of
  # blocking — refusing to continue there would be refusing to reproduce the issue.
  for (( i=0; i<n; i++ )); do
    local url="http://$WS_BIND:${EAP_HTTP[$i]}/$APP_CONTEXT/$APP_PROBE"
    if ! wait_for_http "$url" 200 120; then
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
      if [[ "${GATE4_MODE:-block}" == "measure" ]]; then
        warn "${EAP_NODES[$i]}: $url -> $code (recorded, not blocking: this is a deployment case)"
        continue
      fi
      blocked "${EAP_NODES[$i]}: $url returned $code, not 200.
       The application is not actually serving. If this is EAP 8 and the WAR uses javax.*,
       it will deploy successfully and 404 on every request — check the namespace before
       reading anything into the customer's symptom."
    fi
    info "${EAP_NODES[$i]} $url -> 200"
  done
  ok "application answers on every node"

  step "Gate 5/5 — request routing"
  # No load balancer is used: requests go straight to each node and the JSESSIONID cookie
  # is replayed against the others. That tests replication itself rather than the LB's
  # stickiness, which is the stronger check for a session-loss case.
  if (( n > 1 )); then
    local seen=""
    for (( i=0; i<n; i++ )); do
      local h
      h="$(curl -s -D- -o /dev/null --max-time 10 "http://$WS_BIND:${EAP_HTTP[$i]}/$APP_CONTEXT/$APP_PROBE" \
           | grep -i '^X-Repro-Node:' | tr -d '\r' | awk '{print $2}' || true)"
      seen+=" ${h:-?}"
    done
    info "node identity per port:$seen"
    DEVIATIONS+=("load balancer: none — the harness addresses nodes directly and replays the session cookie (tests replication rather than LB stickiness)")
  fi
  ok "all five startup gates passed"
}

# --- baseline ----------------------------------------------------------------
# Nothing may be broken until the feature is proven to work. Without this, a permanently
# broken lab reports "reproduced" for every case fed to it.
eap_baseline_session() {
  step "Baseline — session replication works BEFORE anything is broken"
  local jar="$PKG/evidence/before/cookies.txt" r1 r2 r3
  rm -f "$jar"

  r1="$(curl -s -c "$jar" --max-time 10 "http://$WS_BIND:${EAP_HTTP[0]}/$APP_CONTEXT/session?set=probe:v1")"
  printf '%s\n' "$r1" >"$PKG/evidence/before/session-node1-first.json"
  BASE_SID="$(grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$r1" | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
  [[ -n "$BASE_SID" ]] || blocked "no sessionId in the baseline response — the probe servlet is not answering as expected:
$(head -c 400 <<<"$r1")"
  info "session created on ${EAP_NODES[0]}: $BASE_SID"

  r2="$(curl -s -b "$jar" -c "$jar" --max-time 10 "http://$WS_BIND:${EAP_HTTP[0]}/$APP_CONTEXT/session")"
  printf '%s\n' "$r2" >"$PKG/evidence/before/session-node1-second.json"
  grep -q '"counter"[[:space:]]*:[[:space:]]*2' <<<"$r2" \
    || blocked "the session did not survive a second request to the SAME node.
       That is a broken harness, not a clustering issue. Response: $(head -c 300 <<<"$r2")"
  ok "session sticky on its own node (counter reached 2)"

  if (( ${#EAP_NODES[@]} < 2 )); then
    BASELINE_REPLICATED=na; export BASELINE_REPLICATED BASE_SID; return 0
  fi

  r3="$(curl -s -b "$jar" -c "$jar" --max-time 10 "http://$WS_BIND:${EAP_HTTP[1]}/$APP_CONTEXT/session")"
  printf '%s\n' "$r3" >"$PKG/evidence/before/session-node2-replica.json"
  if grep -q '"existedBeforeRequest"[[:space:]]*:[[:space:]]*true' <<<"$r3"; then
    BASELINE_REPLICATED=yes
    ok "session replicated to ${EAP_NODES[1]} — baseline passes"
  else
    BASELINE_REPLICATED=no
    warn "session did NOT replicate to ${EAP_NODES[1]} at baseline"
    warn "response: $(head -c 300 <<<"$r3")"
  fi
  export BASELINE_REPLICATED BASE_SID
}

# --- injection ---------------------------------------------------------------
eap_kill_node() {
  local idx="$1"
  local node="${EAP_NODES[$idx]}"
  step "Injecting failure — killing $node"
  kill_recorded_pid "$PKG/nodes/$node.pid" "jboss.node.name=$node" TERM
  if ! wait_for_port_closed "$WS_BIND" "${EAP_HTTP[$idx]}" 45; then
    warn "$node still listening after SIGTERM — escalating to SIGKILL"
    local pid; pid="$(java_pid_for "jboss.node.name=$node" || true)"
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    wait_for_port_closed "$WS_BIND" "${EAP_HTTP[$idx]}" 30 \
      || blocked "$node would not die (port ${EAP_HTTP[$idx]} still open).
       A node that is still serving makes a failover result meaningless — INCONCLUSIVE."
  fi
  ok "$node is down (port ${EAP_HTTP[$idx]} closed)"
  # The survivors must notice, or the test measures the window before detection rather
  # than the failover itself.
  local log="$PKG/nodes/${EAP_NODES[1]}/log/server.log"
  # EAP 8 does not log a new channel view when a member goes; what it logs is the cache
  # membership update and ISPN100001 "Node <name> left the cluster".
  [[ -f "$log" ]] && wait_for_log "$log" 'ISPN000094|ISPN100001|ISPN100008|left the cluster|Received new cluster view|suspect' 60 \
    && info "survivor observed the view change" || warn "survivor did not log a view change within 60s"
}

# --- measurement -------------------------------------------------------------
# Three-valued on purpose. Anything that is neither the expected-good nor the expected-bad
# outcome is INCONCLUSIVE and counted as neither.
eap_measure_failover() {
  step "Measuring — replaying the session cookie against the surviving node"
  local jar="$PKG/evidence/before/cookies.txt" r sid existed code
  local url="http://$WS_BIND:${EAP_HTTP[1]}/$APP_CONTEXT/session"

  code="$(curl -s -o "$PKG/evidence/during/session-after-failover.json" -w '%{http_code}' \
          -b "$jar" --max-time 15 "$url" || true)"
  r="$(cat "$PKG/evidence/during/session-after-failover.json" 2>/dev/null || true)"

  if [[ "$code" != "200" ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the surviving node returned HTTP $code, so no statement about the session is possible (request never landed — not a data finding)"
    return 0
  fi

  sid="$(grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$r" | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
  existed="$(grep -oE '"existedBeforeRequest"[[:space:]]*:[[:space:]]*(true|false)' <<<"$r" | grep -oE 'true|false' || true)"

  {
    printf 'baseline session id : %s\n' "$BASE_SID"
    printf 'post-failover id    : %s\n' "${sid:-NONE}"
    printf 'existed before req  : %s\n' "${existed:-UNKNOWN}"
    printf 'raw response        : %s\n' "$r"
  } >"$PKG/evidence/during/failover-comparison.txt"

  if [[ "$existed" == "true" ]]; then
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="the session survived the node loss: ${EAP_NODES[1]} served the pre-existing session $sid after ${EAP_NODES[0]} was killed"
  elif [[ "$existed" == "false" ]]; then
    VERDICT="REPRODUCED"
    VERDICT_WHY="the session was lost: after ${EAP_NODES[0]} died, ${EAP_NODES[1]} issued a NEW session (${sid:-?}) instead of the replicated one ($BASE_SID) — the customer's reported symptom"
  else
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the probe response did not carry existedBeforeRequest, so survival could not be decided from data"
  fi
}

# Deployment cases: the question is whether the artifact deployed AND actually serves.
# Those two are independent, and treating them as one is the whole bug class.
eap_measure_deployment() {
  step "Measuring — deployment status vs. what the endpoint actually returns"
  local node="${EAP_NODES[0]}"
  local log="$PKG/nodes/$node/log/server.log" url code marker=""
  [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
  url="http://$WS_BIND:${EAP_HTTP[0]}/$APP_CONTEXT/$APP_PROBE"
  code="$(curl -s -o "$PKG/evidence/during/endpoint-response.txt" -w '%{http_code}' --max-time 10 "$url" || echo 000)"

  local deployed failed
  deployed="$(count_matches "$log" 'WFLYSRV0010|WFLYUT0021')"
  failed="$(count_matches "$log" 'WFLYSRV0059|WFLYCTL0412|WFLYSRV0021')"
  compgen -G "$PKG/nodes/$node/deployments/*.deployed" >/dev/null 2>&1 && marker="deployed"
  compgen -G "$PKG/nodes/$node/deployments/*.failed"   >/dev/null 2>&1 && marker="failed"

  {
    printf 'deployment success messages : %s\n' "$deployed"
    printf 'deployment failure messages : %s\n' "$failed"
    printf 'scanner marker              : %s\n' "${marker:-none}"
    printf 'GET %s -> %s\n' "$url" "$code"
  } | tee "$PKG/evidence/during/deployment-check.txt"

  if [[ "$failed" != "0" || "$marker" == "failed" ]]; then
    VERDICT="REPRODUCED"
    VERDICT_WHY="the deployment failed outright ($failed failure message(s), marker=${marker:-none}); the endpoint returned $code. See logs/$node-server.log."
  elif [[ "$code" == "200" ]]; then
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="the artifact deployed and $url returned 200 — it is genuinely serving, not merely reported as deployed"
  elif [[ "$deployed" != "0" ]]; then
    VERDICT="REPRODUCED"
    VERDICT_WHY="the artifact reported a SUCCESSFUL deployment yet $url returns $code. On EAP $WS_MAJOR that pattern is the javax/jakarta namespace mismatch: the WAR deploys, the annotations are never scanned, and every servlet 404s with no error logged."
  else
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="neither a deployment success nor a failure message was found in $log, and the endpoint returned $code — the state of the deployment could not be established"
  fi
}

# Cluster-formation cases: the question is whether N nodes converge on ONE view.
#
# The failure mode this guards against is the quiet one. When discovery does not work, no
# node logs an error — each simply forms a cluster of one and reports itself healthy. So the
# measurement is the smallest view held by any node, not the largest, and not the absence of
# errors in the log.
eap_measure_cluster_formation() {
  local n="${#EAP_NODES[@]}"
  step "Measuring — do all $n nodes converge on one view over the '$JG_STACK' stack?"
  local ev="$PKG/evidence/during/cluster-formation.txt"

  if eap_cluster_probe "$ev" 180; then
    cat "$ev"
    CLUSTER_FORMED_ON="$JG_STACK"
    export CLUSTER_FORMED_ON

    # Forming a cluster on udp does not settle a udp-won't-form case; it usually means the lab
    # is too kind. Every node here shares one host, and the kernel hands multicast between
    # local sockets without it ever touching a network. The customer has no such shortcut. So
    # do not stop at "could not reproduce" while an interface on this very host is measured to
    # drop the discovery datagram — move the nodes there and ask again.
    local blocked_addr=""
    if [[ "$JG_STACK" == "udp" ]]; then blocked_addr="$(diag_blocked_multicast_addr)"; fi
    if [[ -n "$blocked_addr" && "${EAP_PRIVATE_BIND:-$WS_BIND}" == "$WS_BIND" ]]; then
      eap_escalate_blocked_multicast "$blocked_addr"
      return 0
    fi

    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="all $n nodes formed a single cluster on the '$JG_STACK' stack and each one sees all $n members (evidence/during/cluster-formation.txt). The customer's symptom did not occur under this configuration — see configuration-diff.txt for what differs from theirs, starting with the fact that all $n nodes here run on one host."
    return 0
  fi

  cat "$ev"
  VERDICT="REPRODUCED"
  VERDICT_WHY="the cluster did not form on the '$JG_STACK' stack: after a full boot and 180s of polling, the smallest view any node held was ${CLUSTER_MIN_MEMBERS:-0} of $n. No node logged an error — each simply formed a cluster of one, which is the customer's symptom exactly (evidence/during/cluster-formation.txt)."
  CLUSTER_FORMED_ON=""
  # Pin the failure number now: the remediation ladder re-probes and overwrites
  # CLUSTER_MIN_MEMBERS, and the report needs the before/after pair, not the after twice.
  CLUSTER_MIN_MEMBERS_AT_FAILURE="${CLUSTER_MIN_MEMBERS:-0}"
  CLUSTER_STACK_AT_FAILURE="$JG_STACK"
  export CLUSTER_FORMED_ON CLUSTER_MIN_MEMBERS_AT_FAILURE CLUSTER_STACK_AT_FAILURE

  diag_discovery_log "$PKG/evidence/during/discovery-lines.txt"
  diag_jgroups_bindings "$PKG/evidence/during/jgroups-bindings.txt"
  return 0
}

# Second attempt for a udp case that refused to fail on loopback: rebind JGroups to an
# interface where multicast was MEASURED to be dropped, and re-ask the question.
#
# What this is and is not. It is not injecting a fault and it is not sabotage — no firewall
# rule is added, nothing is broken, and the product configuration is untouched. It moves the
# nodes onto a network path this host already has, whose behaviour was measured minutes
# earlier by the probe, and which matches the customer's: discovery datagrams that must leave
# the machine and do not arrive. Reproducing their CONDITION is the only honest way to
# reproduce their symptom; asserting the symptom would be the dishonest one.
#
# Only the private/JGroups binding moves. HTTP and management stay on the loopback address, so
# nothing this run serves becomes reachable from the LAN.
eap_escalate_blocked_multicast() {
  local addr="$1" n="${#EAP_NODES[@]}"
  local ev="$PKG/evidence/during/cluster-formation-blocked-multicast.txt"

  step "The cluster formed on loopback — retrying on $addr, where multicast is measured to fail"
  info "loopback lets the kernel deliver discovery locally; the customer's nodes are on separate hosts"

  cp -f "$PKG/evidence/during/cluster-formation.txt" \
        "$PKG/evidence/during/cluster-formation-loopback.txt" 2>/dev/null || true

  eap_cycle_begin "udp-on-blocked-multicast"
  EAP_PRIVATE_BIND="$addr"; export EAP_PRIVATE_BIND
  DEVIATIONS+=("JGroups was rebound from $WS_BIND to $addr for the second measurement. Multicast was measured to work on $WS_BIND (kernel-local delivery) and to fail on $addr (probe: datagram never returned), and only the second matches a customer whose nodes are on separate hosts. HTTP and management stayed on $WS_BIND.")

  if ! eap_cycle_end; then
    VERDICT="INCONCLUSIVE"
    VERDICT_WHY="the nodes formed a cluster on the udp stack over $WS_BIND, but that is a single-host artifact — multicast there is delivered by the kernel without crossing a network. The re-test bound to $addr, where multicast is measured to fail, could not be judged because the nodes did not complete boot after rebinding (logs/*-udp-on-blocked-multicast.log)."
    return 0
  fi

  if eap_cluster_probe "$ev" 180; then
    cat "$ev"
    VERDICT="NOT REPRODUCED"
    VERDICT_WHY="all $n nodes formed a single cluster on the udp stack twice — over $WS_BIND, and again over $addr, an interface where the multicast probe measured that a datagram does not come back (evidence/before/multicast-probe.txt). The customer's symptom did not occur either way, so what distinguishes their environment is not covered by this run; see configuration-diff.txt."
    CLUSTER_FORMED_ON="udp"
    export CLUSTER_FORMED_ON
    return 0
  fi

  cat "$ev"
  VERDICT="REPRODUCED"
  VERDICT_WHY="the cluster did not form on the udp stack once discovery had to cross a real network: with JGroups bound to $addr, the smallest view any node held after 180s was ${CLUSTER_MIN_MEMBERS:-0} of $n, and no node logged an error — each formed a cluster of one, which is the customer's symptom (evidence/during/cluster-formation-blocked-multicast.txt). The same nodes, same configuration and same udp stack DID form a cluster of $n minutes earlier over $WS_BIND (evidence/during/cluster-formation-loopback.txt), which isolates the cause precisely: not the EAP configuration, but whether the multicast datagram is delivered. On $WS_BIND the kernel delivers it locally; on $addr it is dropped, exactly as the probe measured before either attempt."
  CLUSTER_FORMED_ON=""
  CLUSTER_MIN_MEMBERS_AT_FAILURE="${CLUSTER_MIN_MEMBERS:-0}"
  CLUSTER_FAILED_BIND="$addr"
  # Pin the stack too. The remediation ladder sets JG_STACK=tcp at its last rung, so a report
  # that reads JG_STACK afterwards labels the failing row "tcp" — naming the fix as the cause.
  CLUSTER_STACK_AT_FAILURE="$JG_STACK"
  export CLUSTER_FORMED_ON CLUSTER_MIN_MEMBERS_AT_FAILURE CLUSTER_FAILED_BIND CLUSTER_STACK_AT_FAILURE

  diag_discovery_log "$PKG/evidence/during/discovery-lines.txt"
  diag_jgroups_bindings "$PKG/evidence/during/jgroups-bindings.txt"
  return 0
}

# --- remediation ---------------------------------------------------------------
# Having reproduced the failure, find a configuration that fixes it — by trying them.
#
# A ranked list of likely causes is worth less than one change proven to work on the same
# nodes, in the same run, minutes apart. Each rung is applied for real, the servers are
# restarted, and the cluster is re-probed; the ladder stops at the first rung that forms a
# cluster of N. What it produces is not advice, it is a result.
#
# The honesty constraint: a rung that works HERE is a candidate for the customer, not a
# conclusion about them. This lab runs every node on one host, so the fix that works here
# may be fixing a lab-shaped instance of their problem. SOLUTION.md says so.
eap_remediate_cluster() {
  local n="${#EAP_NODES[@]}" ladder="$PKG/evidence/after/remediation-ladder.txt"
  local rung=0 label desc ev
  REMEDY_FOUND=""; REMEDY_DESC=""; REMEDY_CONFIG=""
  export REMEDY_FOUND REMEDY_DESC REMEDY_CONFIG

  # Every rung is tested on the binding that FAILED, not on loopback. If the failure was only
  # reproducible once discovery had to cross a network, then a rung that quietly moves back to
  # loopback is not a fix — it is the lab forgiving itself, and it would be reported as a
  # proven remedy that does nothing for a customer with three separate machines.
  local base_bind="${CLUSTER_FAILED_BIND:-$WS_BIND}"

  step "Remediation — trying candidate fixes until the cluster actually forms"
  {
    printf 'Reproduced: %s nodes did not form a cluster on the %s stack.\n' "$n" "$JG_STACK"
    printf 'JGroups bound to %s for every rung below (the binding the failure was measured on).\n' "$base_bind"
    printf 'Each rung was APPLIED and RE-TESTED on these same nodes.\n\n'
  } >"$ladder"

  # --- rung 1: force the IPv4 stack -------------------------------------------
  # The most common real-world cause of "multicast worked yesterday": the JVM picks the IPv6
  # stack, joins an IPv6 group, and never meets a peer that chose IPv4. Cheap to test and it
  # costs nothing to leave on, so it is first.
  rung=$((rung+1))
  label="udp + preferIPv4Stack"
  desc="-Djava.net.preferIPv4Stack=true on every node (forces the IPv4 multicast group)"
  eap_cycle_begin "$label"
  EAP_EXTRA_PROPS=(-Djava.net.preferIPv4Stack=true)
  EAP_PRIVATE_BIND="$base_bind"
  export EAP_EXTRA_PROPS EAP_PRIVATE_BIND
  if eap_cycle_end; then
    ev="$PKG/evidence/after/attempt-$rung-$(slugify "$label").txt"
    if eap_cluster_probe "$ev" 120; then
      REMEDY_FOUND="$label"; REMEDY_DESC="$desc"
      REMEDY_CONFIG='Add to each node'"'"'s JAVA_OPTS (standalone.conf):

    JAVA_OPTS="$JAVA_OPTS -Djava.net.preferIPv4Stack=true"'
      printf 'rung %s  %-34s FORMED (%s/%s)   %s\n' "$rung" "$label" "$CLUSTER_MIN_MEMBERS" "$n" "$desc" >>"$ladder"
      ok "rung $rung FIXED IT: $label"
      cat "$ladder"; return 0
    fi
    printf 'rung %s  %-34s still %s/%s      %s\n' "$rung" "$label" "${CLUSTER_MIN_MEMBERS:-0}" "$n" "$desc" >>"$ladder"
    warn "rung $rung did not help (smallest view ${CLUSTER_MIN_MEMBERS:-0}/$n)"
  else
    printf 'rung %s  %-34s NODE DID NOT BOOT — not judged\n' "$rung" "$label" >>"$ladder"
  fi

  # --- rung 2: move JGroups to an interface that can actually do multicast -----
  # Only attempted when the probe PROVED a datagram makes the round trip there. Trying an
  # interface the measurement already ruled out would burn three minutes to re-learn a fact
  # the package already contains. Only the private (JGroups) binding moves; http and the
  # management interface stay on loopback, so nothing becomes reachable off this machine.
  #
  # A candidate that is merely loopback is rejected when the failure was measured off
  # loopback. Multicast does work on `lo` here — the kernel delivers it locally — so this rung
  # would "form a cluster of 3" and be written up as a proven fix, when what it proves is only
  # that three JVMs on one machine can talk to themselves. That is not available to a customer
  # running three hosts, and offering it as the answer would be worse than finding nothing.
  local addr=""
  local cand
  for cand in ${MCAST_OK_ON:-}; do
    [[ "$cand" == "$base_bind" ]] && continue
    if [[ "$base_bind" != 127.* && "$cand" == 127.* ]]; then
      printf 'rung -   %-34s REJECTED — %s is loopback; the failure is on %s, and a cluster\n' \
             "udp on $cand" "$cand" "$base_bind" >>"$ladder"
      printf '%9s%-34s formed over loopback would not transfer to separate hosts\n' "" "" >>"$ladder"
      continue
    fi
    addr="$cand"; break
  done

  if [[ -n "$addr" ]]; then
    rung=$((rung+1))
    label="udp on $addr"
    desc="JGroups bound to $addr, an interface where a multicast datagram was measured to work"
    eap_cycle_begin "$label"
    EAP_PRIVATE_BIND="$addr"
    EAP_EXTRA_PROPS=(-Djava.net.preferIPv4Stack=true)
    export EAP_PRIVATE_BIND EAP_EXTRA_PROPS
    if eap_cycle_end; then
      ev="$PKG/evidence/after/attempt-$rung-$(slugify "$label").txt"
      if eap_cluster_probe "$ev" 120; then
        REMEDY_FOUND="$label"; REMEDY_DESC="$desc"
        REMEDY_CONFIG="Bind the private (JGroups) interface to a multicast-capable address:

    ./standalone.sh -c standalone-ha.xml -bprivate $addr"
        printf 'rung %s  %-34s FORMED (%s/%s)   %s\n' "$rung" "$label" "$CLUSTER_MIN_MEMBERS" "$n" "$desc" >>"$ladder"
        ok "rung $rung FIXED IT: $label"
        cat "$ladder"; return 0
      fi
      printf 'rung %s  %-34s still %s/%s      %s\n' "$rung" "$label" "${CLUSTER_MIN_MEMBERS:-0}" "$n" "$desc" >>"$ladder"
      warn "rung $rung did not help (smallest view ${CLUSTER_MIN_MEMBERS:-0}/$n)"
    else
      printf 'rung %s  %-34s NODE DID NOT BOOT — not judged\n' "$rung" "$label" >>"$ladder"
    fi
    EAP_PRIVATE_BIND="$base_bind"; export EAP_PRIVATE_BIND
  else
    printf 'rung -   %-34s SKIPPED — the probe found no usable address on this host where a\n' "udp on another interface" >>"$ladder"
    printf '%9s%-34s multicast datagram completes a round trip (evidence/before/multicast-probe.txt)\n' "" "" >>"$ladder"
    info "skipping the 'other interface' rung: no address on this host passed the multicast probe"
  fi

  # --- rung 3: stop using multicast ---------------------------------------------
  # TCPPING with an explicit initial_hosts needs no multicast at all. This is the change Red
  # Hat's own guidance points at for any environment where multicast is not guaranteed, and
  # it is the rung that is expected to work — but it is still applied and re-tested, because
  # "expected to work" is what this whole tool exists to stop people from writing.
  rung=$((rung+1))
  label="tcp + TCPPING"
  desc="the tcp stack with TCPPING(initial_hosts) — no multicast involved at any point"
  eap_cycle_begin "$label"
  # Still on base_bind: proving TCPPING over loopback would prove nothing about the path that
  # failed. TCPPING is unicast TCP, so it has to be shown working on the same interface whose
  # multicast was dropped — that is what makes it an answer to this failure rather than a
  # generally sensible idea.
  EAP_EXTRA_PROPS=(); EAP_PRIVATE_BIND="$base_bind"
  JG_STACK="tcp"
  export EAP_EXTRA_PROPS EAP_PRIVATE_BIND JG_STACK
  eap_apply_tcpping
  if eap_cycle_end; then
    ev="$PKG/evidence/after/attempt-$rung-$(slugify "$label").txt"
    if eap_cluster_probe "$ev" 120; then
      local hosts="" i
      for (( i=0; i<n; i++ )); do hosts+="${hosts:+,}$base_bind[${EAP_JGROUPS[$i]}]"; done
      REMEDY_FOUND="$label"; REMEDY_DESC="$desc"
      REMEDY_CONFIG="Replace multicast discovery with an explicit host list. Offline, per node:

    /subsystem=jgroups/stack=tcp/protocol=MPING:remove()
    /subsystem=jgroups/stack=tcp/protocol=TCPPING:add(add-index=0, \\
        properties={initial_hosts=\"<host1>[7600],<host2>[7600],<host3>[7600]\", port_range=0})
    /subsystem=jgroups/channel=ee:write-attribute(name=stack, value=tcp)

In this run the list was: $hosts"
      printf 'rung %s  %-34s FORMED (%s/%s)   %s\n' "$rung" "$label" "$CLUSTER_MIN_MEMBERS" "$n" "$desc" >>"$ladder"
      ok "rung $rung FIXED IT: $label"
      cat "$ladder"; return 0
    fi
    printf 'rung %s  %-34s still %s/%s      %s\n' "$rung" "$label" "${CLUSTER_MIN_MEMBERS:-0}" "$n" "$desc" >>"$ladder"
  else
    printf 'rung %s  %-34s NODE DID NOT BOOT — not judged\n' "$rung" "$label" >>"$ladder"
  fi

  # Nothing worked. That is a result too, and a more interesting one than a fix: it means
  # the obstacle is below the product.
  warn "no rung on the ladder formed a cluster"
  printf '\nNo candidate fix formed a cluster of %s. The obstacle is below the product\n' "$n" >>"$ladder"
  printf 'configuration — look at the host: firewall, network namespace, or the JGroups\n' >>"$ladder"
  printf 'ports themselves. See evidence/before/host-network.txt.\n' >>"$ladder"
  cat "$ladder"
  return 0
}

# --- shutdown ----------------------------------------------------------------
eap_stop_all() {
  local i node
  # This runs from the EXIT trap, which fires on paths where the node list was never built.
  # `${#EAP_NODES[@]:-0}` is not valid substitution syntax, and the error it raised here is
  # why an aborted run used to leave its servers behind.
  declare -p EAP_NODES >/dev/null 2>&1 || return 0
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    node="${EAP_NODES[$i]}"
    [[ -f "$PKG/nodes/$node.pid" ]] && kill_recorded_pid "$PKG/nodes/$node.pid" "jboss.node.name=$node" TERM
  done
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    wait_for_port_closed "$WS_BIND" "${EAP_HTTP[$i]}" 30 || true
  done
  return 0
}

eap_collect_logs() {
  local i node
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    node="${EAP_NODES[$i]}"
    [[ -f "$PKG/nodes/$node/log/server.log" ]] && cp "$PKG/nodes/$node/log/server.log" "$PKG/logs/$node-server.log"
    cp "$PKG/nodes/$node/configuration/$SERVER_CONFIG" "$PKG/config/$node-$SERVER_CONFIG" 2>/dev/null || true
  done
  # Grep out what a support engineer reads first.
  grep -hE 'ISPN000094|ISPN000093|WFLYCLINF|WFLYSRV0026|ERROR|SEVERE' "$PKG"/logs/*-server.log 2>/dev/null \
    | head -300 >"$PKG/evidence/after/log-highlights.txt" || true
  return 0
}
