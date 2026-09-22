#!/usr/bin/env bash
# diagnose.sh — measure the host before blaming the product.
#
# A clustering reproduction has two candidate defendants: the customer's configuration and
# the machine the lab happens to run on. Every function here answers a question about the
# machine with a measurement rather than a claim, and writes the raw output into the package
# so the answer can be checked by someone who was not there.
#
# Nothing in this file decides a verdict. It produces facts; the driver decides.

# --- host networking ---------------------------------------------------------
# Interface flags, firewall state and multicast routes, verbatim. Cheap, and it is the first
# thing anyone reading the package will want.
diag_host_network() {
  local out="$1"
  {
    printf '=== interfaces ===\n'
    ip -o link show 2>/dev/null || true
    printf '\n=== addresses ===\n'
    ip -o -4 addr show 2>/dev/null || true
    printf '\n=== IPv4 multicast routes ===\n'
    ip -4 route show table all 2>/dev/null | grep -E '^multicast|224\.0\.0\.0' || printf '(none)\n'
    printf '\n=== firewalld ===\n'
    if have systemctl; then
      printf 'state: %s\n' "$(systemctl is-active firewalld 2>/dev/null || echo unknown)"
    fi
    have firewall-cmd && { firewall-cmd --list-all 2>/dev/null || printf '(firewall-cmd needs privileges)\n'; }
    printf '\n=== listening sockets in this run'"'"'s port range ===\n'
    (ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null) | head -40 || true
  } >"$out" 2>&1
  info "host networking recorded: ${out#"$PKG"/}"
  return 0
}

# Addresses worth testing for multicast: the bind address this run uses, plus every non
# loopback IPv4 address on an interface that is up and carries the MULTICAST flag.
diag_candidate_addresses() {
  local seen=" " a iface
  printf '%s\n' "$WS_BIND"
  while read -r iface a; do
    [[ -z "$iface" || -z "$a" ]] && continue
    [[ "$a" == "$WS_BIND" ]] && continue
    [[ "$seen" == *" $a "* ]] && continue
    # Skip container and tunnel plumbing: a bridge the product will never bind to is noise.
    case "$iface" in lo|veth*|docker*|podman*|cni*|br-*|virbr*|tun*|tap*) continue ;; esac
    ip -o link show "$iface" 2>/dev/null | grep -q 'MULTICAST' || continue
    ip -o link show "$iface" 2>/dev/null | grep -q 'state UP\|LOWER_UP' || continue
    seen+="$a "
    printf '%s\n' "$a"
  done < <(ip -o -4 addr show 2>/dev/null | awk '{split($4,p,"/"); print $2, p[1]}' || true)
  return 0
}

# Does multicast actually work? Compiled and run with the SAME JDK the servers use, because
# the answer is partly a JVM question (IPv4 vs IPv6 stack selection) and testing it with a
# different JVM answers about a different JVM.
#
# Sets MCAST_OK_ON to the addresses where a datagram made the round trip, and MCAST_FAIL_ON
# to those where it did not. Both halves are useful and for different reasons: OK addresses
# are where the udp stack can be made to work, and FAIL addresses are where it cannot — which
# is the customer's condition, and therefore where their symptom can be reproduced.
#
# Neither list is derived from the interface's MULTICAST flag. Measured on this host, the flag
# gets the answer wrong in BOTH directions: `lo` has no MULTICAST flag and carries the datagram
# fine (the kernel delivers multicast between local sockets regardless), while a flagged
# wireless interface silently drops it. Only the round trip decides.
diag_multicast() {
  local outdir="$1" src="$TEMPLATES_DIR/apps/mcast-probe/McastProbe.java"
  local build="$PKG/app/mcast-probe" addr rc report="$outdir/multicast-probe.txt"
  MCAST_OK_ON=""; MCAST_FAIL_ON=""
  export MCAST_OK_ON MCAST_FAIL_ON

  [[ -f "$src" ]] || { warn "multicast probe source missing: $src"; return 0; }
  mkdir -p "$build"
  if ! "$JAVA_HOME/bin/javac" -d "$build" "$src" >>"$COMMANDS_LOG" 2>&1; then
    warn "could not compile the multicast probe — skipping the active test"
    return 0
  fi

  : >"$report"
  step "Diagnostic — is IP multicast usable on this host?"
  local out reason
  while read -r addr; do
    [[ -z "$addr" ]] && continue
    rc=0
    # Capture THIS address's output rather than grepping the cumulative report afterwards:
    # a `grep -m1` over the whole file returns the first address's reason for every
    # subsequent one, which reads as though a working interface had failed for a reason
    # that belongs to loopback.
    out="$("$JAVA_HOME/bin/java" -cp "$build" -Djava.net.preferIPv4Stack=true \
           McastProbe "$addr" "${JG_MCAST_ADDR:-230.0.0.4}" 45688 2>&1)" || rc=$?
    printf -- '--- %s ---\n%s\nexit=%s\n\n' "$addr" "$out" "$rc" >>"$report"
    if (( rc == 0 )); then
      MCAST_OK_ON+="${MCAST_OK_ON:+ }$addr"
      ok "multicast works on $addr"
    else
      MCAST_FAIL_ON+="${MCAST_FAIL_ON:+ }$addr"
      reason="$(grep -m1 'RESULT=FAIL' <<<"$out" | cut -c1-100 || true)"
      info "multicast does NOT work on $addr — ${reason:-no RESULT line}"
    fi
  done < <(diag_candidate_addresses)

  if [[ -z "$MCAST_OK_ON" ]]; then
    warn "no address on this host can exchange a multicast datagram — see ${report#"$PKG"/}"
  fi
  export MCAST_OK_ON MCAST_FAIL_ON
  return 0
}

# The first non-loopback address where multicast was measured NOT to work, or empty.
#
# This is the lab's stand-in for the customer's network. Their nodes are on separate machines,
# so their discovery datagrams have to cross a real network; a node bound here has the same
# problem for the same reason, and the loopback shortcut is unavailable. Loopback is excluded
# even when it fails, because a failure there would not be a network condition.
diag_blocked_multicast_addr() {
  local a
  for a in ${MCAST_FAIL_ON:-}; do
    [[ "$a" == 127.* || "$a" == "::1" ]] && continue
    printf '%s' "$a"; return 0
  done
  return 0
}

# What each node's JGroups socket is actually bound to, read from the running server rather
# than from the configuration that was meant to produce it.
diag_jgroups_bindings() {
  local out="$1" i n="${#EAP_NODES[@]}"
  : >"$out"
  for (( i=0; i<n; i++ )); do
    {
      printf -- '--- %s (mgmt %s) ---\n' "${EAP_NODES[$i]}" "${EAP_MGMT[$i]}"
      eap_cli "${EAP_MGMT[$i]}" '/subsystem=jgroups/channel=ee:read-resource(include-runtime=true)' || true
      eap_cli "${EAP_MGMT[$i]}" '/socket-binding-group=standard-sockets/socket-binding=jgroups-tcp:read-resource(include-runtime=true)' || true
      eap_cli "${EAP_MGMT[$i]}" '/socket-binding-group=standard-sockets/socket-binding=jgroups-udp:read-resource(include-runtime=true)' || true
      eap_cli "${EAP_MGMT[$i]}" '/socket-binding-group=standard-sockets/socket-binding=jgroups-mping:read-resource(include-runtime=true)' || true
      printf '\n'
    } >>"$out" 2>&1
  done
  info "JGroups runtime bindings recorded: ${out#"$PKG"/}"
  return 0
}

# The discovery-related lines every node logged, side by side. When two nodes form two
# clusters of one, neither logs an error — the evidence is in what is absent, so the whole
# set has to be visible at once.
diag_discovery_log() {
  local out="$1" i node log
  : >"$out"
  for (( i=0; i<${#EAP_NODES[@]}; i++ )); do
    node="${EAP_NODES[$i]}"
    log="$PKG/nodes/$node/log/server.log"
    [[ -f "$log" ]] || log="$PKG/logs/$node-console.log"
    {
      printf -- '--- %s (%s) ---\n' "$node" "$(basename "$log")"
      grep -hE 'JGRP|ISPN0000(93|94)|ISPN1000(01|02|08)|WFLYCLJG|channel|discovery|MPING|TCPPING|multicast|Received new|merge' \
        "$log" 2>/dev/null | tail -40 || printf '(no discovery lines)\n'
      printf '\n'
    } >>"$out"
  done
  info "discovery log extract: ${out#"$PKG"/}"
  return 0
}
