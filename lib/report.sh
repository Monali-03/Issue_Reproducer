#!/usr/bin/env bash
# report.sh — package layout, evidence bookkeeping, and the written deliverables:
# VERDICT.txt, README.md, issue-summary.md, configuration-diff.txt and SOLUTION.md.

# --- package -----------------------------------------------------------------
init_package() {
  PKG="$WS_DIR/output/${CASE_ID}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$PKG"/{config,logs,app,nodes,scripts} \
           "$PKG"/evidence/{before,during,after}
  REPRO_LOG="$PKG/reproduction.log"
  COMMANDS_LOG="$PKG/commands.log"
  : >"$REPRO_LOG"; : >"$COMMANDS_LOG"
  export PKG REPRO_LOG COMMANDS_LOG

  cp "$CASE_FILE" "$PKG/issue.txt"          # verbatim, never edited
  # Customer artifacts are copied in, never read from or written back to input/.
  local d
  for d in configs logs dumps attachments; do
    if compgen -G "$WS_DIR/input/$d/*" >/dev/null 2>&1; then
      mkdir -p "$PKG/customer-artifacts/$d"
      cp -r "$WS_DIR/input/$d/." "$PKG/customer-artifacts/$d/" 2>/dev/null || true
    fi
  done

  # Symlink so `output/latest` always points at the most recent run.
  ln -sfn "$(basename "$PKG")" "$WS_DIR/output/latest"

  ok "package: $PKG"
}

# --- environment --------------------------------------------------------------
write_environment() {
  {
    printf 'REPRODUCTION HOST\n=================\n'
    printf 'date          : %s\n' "$(date -Is)"
    printf 'workspace     : %s (%s)\n' "$WS_NAME" "$WS_PRODUCT_LABEL"
    printf 'hostname      : %s\n' "$(hostname)"
    printf 'os            : %s\n' "$(source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
    printf 'kernel        : %s\n' "$(uname -r)"
    printf 'arch          : %s\n' "$(uname -m)"
    printf 'cpus          : %s\n' "$(nproc)"
    printf 'memory        : %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo UNKNOWN)"
    printf 'JAVA_HOME     : %s\n' "${JAVA_HOME:-NOT SET}"
    printf 'java          : %s\n' "$([[ -n "${JAVA_HOME:-}" ]] && "$JAVA_HOME/bin/java" -version 2>&1 | head -1 || echo UNKNOWN)"
    printf 'product home  : %s\n' "${EAP_HOME:-${RHDG_HOME:-n/a}}"
    printf 'product ver   : %s\n' "${EAP_VERSION:-${RHDG_VERSION:-n/a}}"
    printf '\nCUSTOMER ENVIRONMENT (as stated in the case)\n'
    printf '===========================================\n'
    printf 'product       : %s\n' "${CASE_PRODUCT:-NOT PROVIDED}"
    printf 'version       : %s\n' "${CASE_VERSION:-NOT PROVIDED}"
    printf 'jdk           : %s\n' "${CASE_JDK:-NOT PROVIDED}"
    printf 'os            : %s\n' "${CASE_OS:-NOT PROVIDED}"
    printf 'nodes         : %s\n' "${CASE_NODES:-NOT PROVIDED}"
    printf 'mode          : %s\n' "${CASE_MODE:-NOT PROVIDED}"
  } >"$PKG/environment.txt"
}

write_issue_summary() {
  {
    printf '# Issue summary\n\n'
    printf 'Every field is labelled by where it came from. `stated` means the case said so;\n'
    printf '`INFERRED` shows the derivation; `NOT PROVIDED` means it was absent and was not\n'
    printf 'guessed at.\n\n'
    printf '| Field | Value | Source |\n|---|---|---|\n'
    printf '| Case | %s | %s |\n' "${CASE_NUMBER:-NOT PROVIDED}" "$([[ -n "${CASE_NUMBER:-}" ]] && echo stated || echo absent)"
    printf '| Product | %s | %s |\n' "${CASE_PRODUCT:-NOT PROVIDED}" "stated"
    printf '| Version | %s | %s |\n' "${CASE_VERSION:-NOT PROVIDED}" "$([[ -n "${CASE_VERSION:-}" ]] && echo stated || echo absent)"
    printf '| JDK | %s | %s |\n' "${CASE_JDK:-NOT PROVIDED}" "$([[ -n "${CASE_JDK:-}" ]] && echo stated || echo absent)"
    printf '| Nodes reproduced | %s | %s |\n' "$NODE_COUNT" "$NODE_COUNT_SRC"
    printf '| Scenario detected | %s | INFERRED (keyword match against the case text) |\n' "$SCENARIO"
    printf '\n## The case, verbatim\n\n```\n'
    cat "$PKG/issue.txt"
    printf '\n```\n'
  } >"$PKG/issue-summary.md"
}

# --- configuration diff --------------------------------------------------------
# Every way the reproducer differs from the customer's environment, with its impact. This
# is what makes a NOT REPRODUCED verdict honest: the reader can see what was not matched.
write_config_diff() {
  {
    printf 'CONFIGURATION DIFF — reproducer vs. the customer\n'
    printf '===============================================\n\n'
    printf 'Each line is a way this reproduction is NOT the customer environment.\n'
    printf 'Read them before acting on the verdict.\n\n'
    if (( ${#DEVIATIONS[@]} == 0 )); then
      printf '(none recorded)\n'
    else
      local d i=1
      for d in "${DEVIATIONS[@]}"; do printf '%2d. %s\n\n' "$i" "$d"; i=$((i+1)); done
    fi
    printf '\nARTIFACTS SUPPLIED BY THE CUSTOMER\n'
    printf '==================================\n'
    local f any=0
    for f in "$WS_DIR/input"/{configs,logs,dumps,attachments}/*; do
      [[ -e "$f" ]] || continue
      printf '  %-14s %s\n' "$(basename "$(dirname "$f")")" "$(basename "$f")"; any=1
    done
    # `(( x == 0 )) && printf ...` here would make the whole group's exit status 1 whenever
    # artifacts WERE supplied, and under `set -e` that aborts the run at the last step.
    if (( any == 0 )); then
      printf '  NONE. The reproduction ran entirely on defaults — the largest single\n  source of divergence from the customer environment.\n'
    fi
  } >"$PKG/configuration-diff.txt"
  return 0
}

# --- verdict -------------------------------------------------------------------
write_verdict() {
  {
    printf 'VERDICT: %s\n\n' "$VERDICT"
    printf 'why    : %s\n\n' "$VERDICT_WHY"
    printf 'case   : %s\n' "${CASE_NUMBER:-(none)}"
    printf 'product: %s %s\n' "${CASE_PRODUCT:-?}" "${CASE_VERSION:-?}"
    printf 'lab    : %s %s\n' "$WS_PRODUCT_LABEL" "${EAP_VERSION:-${RHDG_VERSION:-${JAVA_VERSION_FULL:-}}}"
    printf 'scenario: %s   nodes: %s\n' "$SCENARIO" "$NODE_COUNT"
    printf 'when   : %s\n' "$(date -Is)"
    printf '\nThis verdict describes THIS lab run. See configuration-diff.txt for every way\n'
    printf 'the lab differs from the customer environment.\n'
  } >"$PKG/VERDICT.txt"

  case "$VERDICT" in
    REPRODUCED)      ok   "VERDICT: REPRODUCED — $VERDICT_WHY" ;;
    "NOT REPRODUCED") info "VERDICT: NOT REPRODUCED — $VERDICT_WHY" ;;
    *)               warn "VERDICT: $VERDICT — $VERDICT_WHY" ;;
  esac
}

# --- evidence manifest ----------------------------------------------------------
write_manifest() {
  ( cd "$PKG" && find evidence logs config app -type f 2>/dev/null \
      | sort | xargs -r sha256sum ) >"$PKG/evidence/MANIFEST.txt" 2>/dev/null || true
  local n; n="$(wc -l <"$PKG/evidence/MANIFEST.txt" 2>/dev/null || echo 0)"
  info "evidence manifest: $n files checksummed"
}

# --- SOLUTION.md ---------------------------------------------------------------
# What to actually do about it.
#
# Scoped deliberately: these are candidate remediations matched to the OBSERVED symptom,
# each with a check that confirms whether it applies. They are not a root-cause finding for
# the customer's system, and no bug IDs, KB article numbers or version-fixed-in claims are
# printed — those cannot be produced without looking them up, and a wrong one costs more
# time than no answer.
write_solution() {
  local f="$PKG/SOLUTION.md"
  {
    printf '# How to solve this — suggested remediation\n\n'
    printf '**Verdict from this run: %s**\n\n' "$VERDICT"
    printf '> Scope: these steps are matched to the symptom this run **observed**, and each\n'
    printf '> one carries a check that tells you whether it applies to the customer. They are\n'
    printf '> candidates to verify, not a root-cause conclusion about the customer'"'"'s system.\n'
    printf '> No bug IDs, KB numbers or "fixed in" claims appear below: those must be looked\n'
    printf '> up on the Red Hat Customer Portal, and a remembered one is worse than none.\n\n'

    if [[ "$VERDICT" == "INCONCLUSIVE" || "$VERDICT" == BLOCKED* ]]; then
      printf '## First: this run did not decide anything\n\n'
      printf '%s\n\n' "$VERDICT_WHY"
      printf 'Fix that before reading the remediation below — acting on an undecided run is\n'
      printf 'how a support case acquires a second, unrelated problem.\n\n'
    fi

    solution_body "$SCENARIO"

    printf '\n---\n\n## Confirming any fix\n\n'
    printf 'Whatever you change, re-run this exact reproducer afterwards:\n\n'
    printf '```bash\ncd %s\n./run.sh\n```\n\n' "$WS_DIR"
    printf 'The verdict must flip from `%s` to the opposite, with the same node count and the\n' "$VERDICT"
    printf 'same scenario. A fix that only changes the wording in the log has not been proven.\n\n'
    printf '## Searching the Customer Portal\n\n'
    printf 'Use these exact terms (drawn from what this run actually produced, not from recall):\n\n'
    portal_search_terms
  } >"$f"
  ok "remediation written: $f"
}

portal_search_terms() {
  local base="${CASE_PRODUCT:-$WS_PRODUCT_LABEL} ${CASE_VERSION:-}"
  printf -- '- `%s %s`\n' "$base" "$SCENARIO"
  local codes
  codes="$(grep -hoE '(WFLY[A-Z]*[0-9]{4,}|ISPN[0-9]{6}|IJ[0-9]{6}|JBWEB[0-9]+|JBAS[0-9]+)' \
            "$PKG"/logs/*.log "$PKG"/evidence/*/*.txt "$PKG/issue.txt" 2>/dev/null \
            | sort -u | head -8 | tr '\n' ' ' || true)"
  if [[ -n "${codes// /}" ]]; then
    local c
    for c in $codes; do printf -- '- `%s %s`\n' "$base" "$c"; done
  else
    printf -- '- (no product message codes appeared in this run'"'"'s logs or in the case)\n'
  fi
}

# The knowledge base. One block per scenario: what this symptom usually is, the check that
# decides it, and the change to make.
solution_body() {
  case "$1" in

  cluster-formation)
    # Led by what the remediation ladder PROVED on these nodes, if anything. A fix that was
    # applied and re-tested minutes ago outranks any list of candidates, so it goes first and
    # the candidates that were tried and failed are named as ruled out rather than omitted.
    # Built before the heredoc, not inside it. A multi-line ${VAR:+...} whose body contains
    # escaped backticks does not parse — bash reports "bad substitution: no closing }" and the
    # whole section is lost.
    local failed_where="" transfer_note=""
    if [[ -n "${CLUSTER_FAILED_BIND:-}" ]]; then
      failed_where=", on \`${CLUSTER_FAILED_BIND}\`"
      transfer_note=" The failure was measured on \`${CLUSTER_FAILED_BIND}\`, an interface where this
run had already proven by experiment that a multicast datagram does not come back — the same
condition the customer's nodes are in, which is not the same as knowing their network. What
transfers is the mechanism, not a diagnosis of their firewall."
    fi

    if [[ -n "${REMEDY_FOUND:-}" ]]; then
      cat <<EOF
## 0. A fix was proven in this run — start here

The reproducer did not stop at reproducing the failure. It applied candidate fixes to the
same $NODE_COUNT nodes, restarted them, and re-tested. This one worked:

> **${REMEDY_FOUND}** — ${REMEDY_DESC}

${REMEDY_CONFIG}

Before and after, on the same hardware, minutes apart:

| | smallest view any node held |
|---|---|
| \`${CLUSTER_STACK_AT_FAILURE:-$JG_STACK}\` as the case describes${failed_where} | ${CLUSTER_MIN_MEMBERS_AT_FAILURE:-1} of $NODE_COUNT |
| after \`${REMEDY_FOUND}\` | $NODE_COUNT of $NODE_COUNT |

Every rung that was tried, including the ones that did not help, is in
\`evidence/after/remediation-ladder.txt\`.

**How far this transfers.** It is a proven fix *here*, and a candidate *there*.${transfer_note}
This lab runs all $NODE_COUNT nodes on one machine, so it can show that discovery fails when
multicast is not delivered and succeeds when discovery does not need multicast — it cannot
tell you *why* multicast is unavailable on the customer's network. Confirm with §1 below
before recommending it.
EOF
    else
      cat <<EOF
## 0. Nothing on the remediation ladder formed a cluster

Every candidate fix was applied to these $NODE_COUNT nodes and re-tested; none produced a
cluster. See \`evidence/after/remediation-ladder.txt\`. That points below the product
configuration — work through §1 and §2 against the host rather than the server config.
EOF
    fi
    cat <<'EOF'

## 1. Prove whether multicast works at all, before changing any server config

This is the question the whole class of issue turns on, and it is answered by measurement,
not by reading interface flags — a flagged interface behind a firewall still drops the
packet. This run's own measurement is in `evidence/before/multicast-probe.txt`.

**Check** — on two of the customer's nodes, using the JGroups testers that ship with EAP:

```bash
# receiver, on node2
java -cp $JBOSS_HOME/modules/system/layers/base/org/jgroups/main/jgroups-*.jar \
     org.jgroups.tests.McastReceiverTest -bind_addr <node2-ip> -mcast_addr 230.0.0.4 -port 45688

# sender, on node1
java -cp $JBOSS_HOME/modules/system/layers/base/org/jgroups/main/jgroups-*.jar \
     org.jgroups.tests.McastSenderTest  -bind_addr <node1-ip> -mcast_addr 230.0.0.4 -port 45688
```

Type into the sender; if nothing arrives at the receiver, no amount of EAP configuration
will form a cluster and everything below §3 is the wrong direction.

Multicast is commonly unavailable and often cannot be turned on: most cloud VPCs
(AWS/Azure/GCP) do not route it at all, nor do most Kubernetes/OpenShift CNI plugins, nor
loopback on a single host — `lo` carries no `MULTICAST` flag on Linux.

## 2. Rule out the host before blaming the product

- **Firewall.** The JGroups port must be open **both** TCP and UDP, and so must the FD_SOCK
  port. `firewall-cmd --list-ports` on every node; the default is 7600 plus the offset.
- **The private interface binding.** `-bprivate` / `jboss.bind.address.private` must be a
  routable address, not `127.0.0.1`. A node bound to loopback is unreachable by definition.
  Confirm from the *running* server, not the config file:

  ```
  /subsystem=jgroups/channel=ee:read-resource(include-runtime=true)
  ```

- **IPv4 vs IPv6.** If one node joins an IPv6 group and another IPv4, they never meet and
  neither logs anything. Set `-Djava.net.preferIPv4Stack=true` on all of them, consistently.
- **TTL.** Across subnets, the default multicast TTL of 2 is often too small.

## 3. Check that the nodes are even trying to join the same cluster

Two nodes with different cluster names, or on different stacks, form two clusters of one and
**neither logs an error**. That silence is the single most misleading thing about this issue
class: it looks healthy from every node.

**Check** — on each node:

```
/subsystem=jgroups/channel=ee:read-attribute(name=stack)
/subsystem=jgroups/channel=ee:read-attribute(name=cluster)
```

Both must be identical across all nodes. On EAP 8.1 note that `standalone-ha.xml` ships
`<channel name="ee" stack="udp" cluster="ejb"/>` with **no expression** around the stack
name — so `-Djboss.default.jgroups.stack=tcp` on the command line is silently ignored there.
Change the attribute itself, not the system property, and read it back.

Also confirm each node has a distinct `jboss.node.name`: duplicates make members overwrite
each other in the view.

## 4. Replace discovery with something that does not need multicast

The standard answer when §1 shows multicast is unavailable. Pick by how dynamic the node set
is:

- **TCPPING** — static, explicit `initial_hosts`. Simplest, and correct when the nodes are
  known in advance. Every node must list every node, including itself.
- **JDBC_PING** — nodes register in a shared database table. The right choice when addresses
  are assigned at boot.
- **DNS_PING / KUBE_PING** — for OpenShift and Kubernetes, where the platform already knows
  the member set. `DNS_PING` against a headless service is the usual EAP-on-OpenShift answer.

Note that TCPPING needs `port_range=0` when every node uses an explicit port, or a node will
also probe neighbouring ports and can pair with the wrong instance on a shared host.

## 5. Verify by the view, never by the absence of errors

A formed cluster is one where **every** node lists **every** member. Checking one node is
how a split cluster gets signed off.

```bash
grep 'ISPN000094' server.log | tail -1     # EAP 7: the running view
```

On EAP 8 that line does not keep appearing — `WFLYCLJG0033` is logged once, at connect, when
the node is still alone, and the jgroups channel's runtime attributes read `undefined` over
the management API even with statistics enabled. Use the Infinispan membership lines instead:

```bash
grep -E 'ISPN100002: Starting rebalance with members|ISPN100001|ISPN100008' server.log | tail
```
EOF
    ;;

  session-failover|clustering)
    cat <<'EOF'
## 1. Is the web application marked distributable?

Without `<distributable/>` the session lives only on the node that created it, and no
amount of clustering configuration will replicate it. This is the single most common cause
of "sessions lost on failover".

**Check** — in the deployed artifact:

```bash
unzip -p your-app.war WEB-INF/web.xml | grep -c distributable
```

**Fix** — add to `WEB-INF/web.xml` (inside `<web-app>`):

```xml
<distributable/>
```

Redeploy. On EAP 8 / Jakarta EE 10 the element is unchanged; only the schema namespace
differs (`https://jakarta.ee/xml/ns/jakartaee`).

## 2. Is the cluster actually forming?

A node that only ever sees itself will fail every failover while logging nothing alarming.

**Check** — each node's `server.log`:

```bash
grep 'ISPN000094' server.log | tail -1
```

The member list must contain **every** node. If each node lists only itself, discovery is
the problem, not replication.

**Fix** — the usual causes, in order of how often they are it:

- **Multicast is not available** on the network (very common in cloud, containers, and any
  single-host lab). Switch the JGroups stack from `udp`/`MPING` to `tcp` with `TCPPING` and
  an explicit `initial_hosts`, or to `JDBC_PING` where the node set is dynamic.
- **The private interface is wrong** — nodes bound their JGroups socket to `127.0.0.1` and
  cannot reach each other. Set `-Djboss.bind.address.private` to a routable address.
- **A firewall blocks the JGroups port** (7600/TCP by default, plus the FD_SOCK port).
  `firewall-cmd --list-ports` on each node.
- **Different cluster names or different stacks** between nodes: they form two clusters of
  one and neither logs an error.

## 3. Is the session cache actually replicating?

**Check** — the web cache container in `standalone-ha.xml`:

```bash
grep -A5 'cache-container name="web"' standalone-ha.xml
```

A `local-cache` here means nothing replicates regardless of `<distributable/>`. It must be
a `distributed-cache` or `replicated-cache`, and `mode` should be `SYNC` when losing a
session on abrupt node death is unacceptable — `ASYNC` has a window in which the session
exists only on the dying node.

## 4. Is the load balancer sticky, and does it fail over?

Non-sticky balancing spreads a session across nodes and looks exactly like replication
failure; sticky balancing that never re-routes looks exactly like an outage.

**Check** — with mod_cluster/mod_proxy, confirm `stickysession=JSESSIONID` and that
`jvmRoute` / `instance-id` is set **per node** and matches the cookie suffix.

**Fix** — set `instance-id` in the undertow subsystem on each node:

```
/subsystem=undertow:write-attribute(name=instance-id,value=${jboss.node.name})
```

## 5. Timing

If sessions survive a *graceful* shutdown but not a *kill*, the replication mode is
asynchronous and the window is real. Move the session cache to `SYNC`, or accept the window
explicitly.
EOF
    ;;

  cache|xsite)
    cat <<'EOF'
## 1. Does the cache have more than one owner?

A distributed cache with `owners="1"` loses every entry whose owner dies. This is by
design, and it is the most common cause of "entries disappear when a node restarts".

**Check**:

```bash
curl -sS --digest -u user:pass \
  'http://host:11222/rest/v2/caches/<cache>?action=config'
```

Look at `owners` for a distributed cache, or confirm the cache is `replicated` if every
node must hold every entry.

**Fix** — `owners="2"` tolerates one node loss; `owners="3"` tolerates two. Changing this
requires recreating the cache: existing entries are not re-distributed retroactively.

## 2. Is the write synchronous?

With `mode="ASYNC"` a write is acknowledged before the backup owner has it. Kill the
primary in that window and the entry is simply gone, with no error anywhere.

**Fix** — `mode="SYNC"` for data that must survive abrupt node loss. Expect a latency cost.

## 3. Was the cluster whole when the entries were written?

Entries written while the cluster was split exist only on one side, and the merge does not
invent them.

**Check** — `ISPN000094` on every node, and confirm the member list matches the expected
topology at the time of the write, not just now.

## 4. Is it actually an authentication failure being read as a cache miss?

Data Grid's properties realm stores **hashed** credentials, so HTTP Basic is rejected even
with the correct password; the server negotiates digest. A client using Basic gets 401/403
on every call — and a naive harness records those as "key not found".

**Check** — compare:

```bash
curl -sS -u user:pass          http://host:11222/rest/v2/caches   # Basic  -> often 401
curl -sS --digest -u user:pass http://host:11222/rest/v2/caches   # Digest -> 200
```

Note that `/health/status` answers **anonymously**, so a readiness probe against it reports
HEALTHY while every real call fails. Never use it to prove credentials work.

## 5. Caches created over REST are permanent

They survive restarts. A cache left over from an earlier configuration keeps its **old**
settings even after the config file is changed. Delete and recreate it after any change to
`owners` or `mode`, and confirm with `?action=config`.

## 6. Cross-site (if relevant)

Backup sites are asynchronous by default and take backups **only** for caches that declare
a `<backups>` section. A cache without one is silently local to its site.
EOF
    ;;

  memory)
    cat <<'EOF'
## 1. Read the OOM message — the wording names the cause

`java.lang.OutOfMemoryError` is a family, not one error:

| Message | What it means | First action |
|---|---|---|
| `Java heap space` | the live set exceeds `-Xmx` | heap dump → find the dominant retainer |
| `GC overhead limit exceeded` | GC runs constantly and reclaims almost nothing | same as above; it is heap space with a slower ending |
| `Metaspace` | class metadata, usually a classloader leak from repeated redeploys | count loaded classes over time; restart between redeploys |
| `unable to create native thread` | OS thread limit or native memory, **not** heap | `ulimit -u`, thread count, container pids limit |
| `Direct buffer memory` | NIO direct buffers | `-XX:MaxDirectMemorySize`, and look for unclosed channels |
| `Requested array size exceeds VM limit` | a genuinely huge single allocation | a bug in the application, not a tuning problem |

Raising `-Xmx` against a leak buys time and nothing else — the OOM returns later and the
heap dump takes longer to produce.

## 2. Get a heap dump from the actual failure

```
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/tmp/
```

This costs nothing until the OOM happens and is the difference between diagnosing the issue
and guessing at it. Analyse with Eclipse MAT: the Leak Suspects report names the retaining
object in most real leaks.

## 3. Confirm growth is monotonic before calling it a leak

A leak grows across **full** GCs. Sawtooth that returns to the same floor after each full GC
is not a leak; it is allocation rate, and the fix is different.

**Check** — from the GC log, compare the used heap immediately after each full GC:

```bash
grep -E 'Full GC|Pause Full' gc.log
```

Rising floor = leak. Flat floor = allocation pressure.

## 4. Always enable GC logging in production

JDK 11+:

```
-Xlog:gc*,safepoint:file=/var/log/gc.log:time,uptime,level,tags:filecount=5,filesize=20M
```

JDK 8:

```
-Xloggc:/var/log/gc.log -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=20M
```

Rotation matters: an unrotated GC log fills the filesystem and causes an unrelated outage.
EOF
    ;;

  deadlock)
    cat <<'EOF'
## 1. Confirm it is a deadlock and not just slowness

The JVM detects Java-level deadlocks itself. Take a thread dump **while the symptom is
live**:

```bash
jcmd <pid> Thread.print -l > dump-1.txt
```

Search for `Found one Java-level deadlock`. If it is not there, the threads are blocked on
something the JVM cannot see as a cycle — a database lock, an exhausted connection pool, or
a remote call with no timeout — and the fix below does not apply.

## 2. Take three dumps, ten seconds apart

One dump shows threads that happen to be busy. Three show which ones never move. Compare
the stack of each `BLOCKED` thread across dumps: a real deadlock is bit-for-bit identical.

## 3. Read the cycle

The deadlock section names both threads, both monitors, and the line numbers. Fix by making
the lock ordering consistent — every code path must acquire the locks in the same sequence.
Alternatives: a single coarser lock, or `tryLock` with a timeout so the cycle breaks itself
and logs instead of hanging.

## 4. If the cycle involves no Java monitors

Then look at, in order of likelihood:

- **Connection pool exhaustion** — threads blocked in `getConnection`. Check the pool's
  `max-pool-size` against the number of concurrent requests, and look for connections that
  are never returned (missing `close()` in a non-`try-with-resources` path).
- **A remote call with no timeout** — every HTTP/JDBC/JMS client must have both a connect
  and a read timeout. Without them one slow dependency consumes the whole request thread
  pool.
- **Synchronous cache operations during a cluster topology change** — threads waiting on a
  node that is no longer there.
EOF
    ;;

  cpu-gc)
    cat <<'EOF'
## 1. Find out which threads are burning the CPU

```bash
top -H -p <pid>                       # per-thread CPU; note the top TIDs
printf '%x\n' <tid>                   # convert to hex
jcmd <pid> Thread.print > dump.txt    # find nid=0x<hex> in the dump
```

This maps CPU to a stack in about a minute, and it decides whether the answer is GC,
application code, or a spinning framework thread.

## 2. If the hot threads are GC threads

The problem is the heap, not the code. From the GC log, measure **GC throughput** — the
percentage of wall-clock time not spent in GC. Below roughly 90% the JVM is in trouble.

Common causes, in order:

- Heap too small for the live set → the collector runs continuously.
- Live set genuinely too large → see the memory remediation (a leak ends here too).
- Wrong collector for the workload: G1 is the sensible default from JDK 9 onwards;
  ParallelGC favours throughput over latency; SerialGC in a container that was given only
  one CPU is a frequent surprise.
- **Container CPU limits**: the JVM sizes its GC thread pool from the CPU count it detects.
  A low limit yields very few GC threads. Verify with `-XX:+PrintFlagsFinal -version | grep
  -E 'ParallelGCThreads|UseG1GC|MaxHeapSize'` **inside the container**.

## 3. If the pauses are the complaint rather than throughput

Measure the actual distribution before tuning; a single long pause and steady 200ms pauses
need different answers.

- G1: set `-XX:MaxGCPauseMillis` to the real requirement and let the collector size the
  regions. Do **not** also pin `-XX:NewSize`/`-XX:MaxNewSize` — fixing the young generation
  removes the adaptation G1 needs to meet the target.
- Humongous allocations (objects over half a region) cause pauses that look random. Check
  `-Xlog:gc+heap=info` for humongous counts, and raise `-XX:G1HeapRegionSize` if they are
  frequent.
- Check for non-GC safepoints too — `-Xlog:safepoint` shows pauses caused by things like
  bias revocation or thread dumps, which are often misattributed to GC.

## 4. If the hot threads are application threads

The stack from step 1 names the method. Nothing else here applies.
EOF
    ;;

  tls)
    cat <<'EOF'
## 1. Get the real error, not the client's summary

```bash
openssl s_client -connect host:443 -servername host -showcerts </dev/null
```

Then re-run the failing call with JSSE debugging on the Java side:

```
-Djavax.net.debug=ssl:handshake
```

The handshake log names the exact step that failed. Working from the application's wrapped
exception instead is what turns a ten-minute problem into a day.

## 2. The four causes, in the order they actually occur

- **Incomplete chain** — the server sends its leaf certificate but not the intermediates.
  Works in browsers (they cache intermediates), fails in Java. Confirm with the
  `s_client` output: every certificate up to, but not including, the root must be present.
- **Missing trust** — the CA is not in the client's truststore. Check with
  `keytool -list -keystore <truststore> | grep -i <ca>`.
- **Hostname mismatch** — the certificate's SAN does not contain the name the client used.
  Java validates SAN, not CN, and has done for years.
- **Protocol or cipher mismatch** — a modern JDK disables TLS 1.0/1.1 and a range of
  ciphers by default. On RHEL the system-wide crypto policy (`update-crypto-policies
  --show`) overrides the JDK's own defaults, which is why the same application can work on
  one RHEL host and fail on another with identical Java configuration.

## 3. Expiry

Check the validity window before anything else — it costs one command and explains a
surprising share of "it broke overnight" reports:

```bash
openssl x509 -in cert.pem -noout -dates -subject -issuer
```
EOF
    ;;

  datasource)
    cat <<'EOF'
## 1. Read the IJ code — it names the failure precisely

- `IJ000453` / `IJ000655` — the pool could not hand out a connection in time. Either the
  pool is too small for the concurrency, or connections are leaking.
- `IJ000459` — the connection failed validation and was destroyed; usually the database
  closed it first.
- `IJ031084` / `IJ031085` — the database refused the credentials or the URL.

## 2. Pool exhaustion vs. leak

**Check** — while the symptom is live:

```
/subsystem=datasources/data-source=<ds>/statistics=pool:read-resource(include-runtime=true)
```

`InUseCount` pinned at `max-pool-size` with `AvailableCount` at zero is exhaustion. If it
stays there after load stops, connections are being leaked rather than merely contended.

Enable leak detection while diagnosing (it is expensive, so remove it afterwards):

```
/subsystem=datasources/data-source=<ds>:write-attribute(name=track-statements,value=true)
```

## 3. Stale connections after a database restart or firewall timeout

A pool that holds connections a firewall has silently dropped will serve dead handles. Both
of these together:

```
/subsystem=datasources/data-source=<ds>:write-attribute(name=validate-on-match,value=true)
/subsystem=datasources/data-source=<ds>:write-attribute(name=background-validation,value=true)
/subsystem=datasources/data-source=<ds>:write-attribute(name=background-validation-millis,value=30000)
```

plus an `<idle-timeout-minutes>` shorter than the firewall's idle timeout.

## 4. Sizing

`max-pool-size` must be at least the peak number of concurrent requests that touch the
database, and the database's own `max_connections` must exceed the sum across all nodes.
A pool larger than the database allows moves the failure to the database, where it is
harder to see.
EOF
    ;;

  deployment)
    cat <<'EOF'
## 1. If this is EAP 8: check the namespace before anything else

EAP 7.x is Jakarta EE 8 and uses `javax.*`. EAP 8.x is Jakarta EE 10 and uses `jakarta.*`.

A WAR built against `javax.*` **deploys successfully** on EAP 8 — the deployment reports
`WFLYSRV0010: Deployed`, the management console shows it green — and every servlet returns
404, because the annotations were never scanned. There is no error message.

**Check**:

```bash
unzip -p your-app.war WEB-INF/classes/**/YourServlet.class | strings | grep -c 'jakarta/servlet'
```

or simply call the endpoint. Deployment status is not evidence that the application works.

**Fix** — rebuild against `jakarta.servlet:jakarta.servlet-api` (6.0.0 for EE 10), update
imports, and set the `web.xml` schema to
`https://jakarta.ee/xml/ns/jakartaee` version `6.0`. Red Hat ships the Migration Toolkit for
Applications to do the bulk of it.

## 2. Read the deployment error by its code

- `WFLYSRV0059` — the deployment failed and the server logged why several lines above.
- `WFLYCTL0412` — required services are missing; the list names what could not be resolved
  (usually a datasource or a JMS destination that does not exist on this node).
- `WFLYSRV0026` — the server started **with errors**. Healthy-looking and not healthy.

## 3. Marker files in `deployments/`

In deployment-scanner mode the markers are the state machine. A leftover `.failed` or
`.isdeploying` blocks a redeploy silently. Remove all markers and re-drop the archive:

```bash
rm -f deployments/*.deployed deployments/*.failed deployments/*.isdeploying
```

Never share one `deployments/` directory between two server instances; they overwrite each
other's markers.

## 4. Classloading

`ClassNotFoundException` for a class that is inside the WAR usually means a module
dependency was excluded, or two copies of the class exist. Add a `jboss-deployment-
structure.xml` rather than dropping jars into `modules/`.
EOF
    ;;

  *)
    cat <<'EOF'
## No scenario-specific remediation was matched

The case text did not contain enough signal to select a remediation path, so nothing is
offered here rather than offering something generic and possibly wrong.

To get targeted output, add to `input/case.txt`:

- the **exact error message** and the product message code (`WFLY…`, `ISPN…`, `IJ…`), copied
  rather than paraphrased
- what the customer **expected** versus what **happened**
- the **steps** that trigger it, and whether it is reproducible on demand
- whether it started after a change (upgrade, patch, config, load)

Then re-run. The reproduction evidence collected by this run is still in `evidence/` and
remains valid input for that analysis.
EOF
    ;;
  esac
}

# --- README ---------------------------------------------------------------------
write_readme() {
  {
    printf '# Reproduction package — %s\n\n' "${CASE_NUMBER:-$CASE_ID}"
    printf '| | |\n|---|---|\n'
    printf '| **Verdict** | **%s** |\n' "$VERDICT"
    printf '| Product | %s %s |\n' "${CASE_PRODUCT:-?}" "${CASE_VERSION:-?}"
    printf '| Lab | %s — %s |\n' "$WS_PRODUCT_LABEL" "${EAP_VERSION:-${RHDG_VERSION:-${JAVA_VERSION_FULL:-n/a}}}"
    printf '| Scenario | %s |\n' "$SCENARIO"
    printf '| Nodes | %s (%s) |\n' "$NODE_COUNT" "$NODE_COUNT_SRC"
    printf '| Run | %s |\n' "$(date -Is)"
    printf '\n## Verdict\n\n%s\n\n' "$VERDICT_WHY"

    printf '## Read these first\n\n'
    printf -- '- **[SOLUTION.md](SOLUTION.md)** — what to do about it\n'
    printf -- '- **[configuration-diff.txt](configuration-diff.txt)** — every way this lab is not the customer\n'
    printf -- '- **[issue-summary.md](issue-summary.md)** — the case, with each field marked stated / INFERRED / NOT PROVIDED\n\n'

    printf '## What was run\n\n```\n'
    printf 'workspace : %s\n' "$WS_DIR"
    printf 'command   : ./run.sh\n'
    printf 'scenario  : %s\n' "$SCENARIO"
    printf 'topology  : %s node(s) on %s\n' "$NODE_COUNT" "$WS_BIND"
    [[ -n "${EAP_HTTP:-}" ]] && printf 'http      : %s\n' "${EAP_HTTP[*]}"
    [[ -n "${DG_PORTS:-}" ]] && printf 'endpoints : %s\n' "${DG_PORTS[*]}"
    printf '```\n\n'

    printf '## Gates\n\nEvery gate below had to pass before the failure was injected. They exist because a\n'
    printf 'lab that is quietly broken reproduces every issue it is given.\n\n'
    printf '%s\n\n' "${GATE_SUMMARY:-(not recorded)}"

    printf '## Package contents\n\n```\n'
    ( cd "$PKG" && find . -maxdepth 2 -not -path './nodes/*' -not -name '.*' | sort | sed 's|^\./||' | head -60 )
    printf '```\n\n'

    printf '## Evidence\n\n'
    if [[ -f "$PKG/evidence/measurement-plan.txt" ]]; then
      # Named first and described this way on purpose: the plan is written before the fault
      # is injected, so reading it before the results is the reader's check that the
      # threshold was not chosen after seeing the number.
      printf -- '- `evidence/measurement-plan.txt` — what this run set out to measure and what would count as the symptom, **written before the fault was injected**\n'
      printf -- '- `evidence/measurement.txt` — the before/after readings and what was injected between them\n'
    fi
    printf -- '- `evidence/before/` — the state with everything healthy, including the passing baseline\n'
    printf -- '- `evidence/during/` — captured while the symptom was live\n'
    printf -- '- `evidence/after/`  — the aftermath, plus log highlights\n'
    printf -- '- `evidence/MANIFEST.txt` — sha256 of every file above\n'
    printf -- '- `commands.log` — every command this run executed, with exit status\n\n'

    printf '## Re-running\n\n```bash\ncd %s\n./run.sh          # same case, fresh package\n' "$WS_DIR"
    printf './run.sh --clean  # stop anything still running and release the ports\n```\n\n'

    printf '## What this run did NOT cover\n\n'
    if (( ${#DEVIATIONS[@]} == 0 )); then
      printf 'Nothing recorded.\n'
    else
      local d
      for d in "${DEVIATIONS[@]}"; do printf -- '- %s\n' "$d"; done
    fi
    printf '\nA verdict of NOT REPRODUCED is only as strong as this list is short.\n'
  } >"$PKG/README.md"
  ok "report written: $PKG/README.md"
}

finalize_package() {
  write_environment
  write_issue_summary
  write_config_diff
  write_verdict
  write_solution
  write_manifest
  write_readme

  local tgz="$WS_DIR/output/$(basename "$PKG").tar.gz"
  # nodes/ holds whole seeded server trees, and a heap dump is routinely 200MB+. Both stay
  # on disk in the package; neither belongs in an archive meant to be attached to a case.
  tar czf "$tgz" -C "$(dirname "$PKG")" --exclude='nodes' --exclude='*.hprof' \
      "$(basename "$PKG")" 2>/dev/null || true
  if [[ -f "$tgz" ]]; then
    ok "archive: $tgz ($(human_size "$(stat -c%s "$tgz")")) — excludes nodes/ and *.hprof"
  fi

  printf '\n'
  step "DONE — $VERDICT"
  printf '  package : %s\n' "$PKG"
  printf '  verdict : %s\n' "$PKG/VERDICT.txt"
  printf '  solution: %s\n' "$PKG/SOLUTION.md"
  printf '  report  : %s\n\n' "$PKG/README.md"
}
