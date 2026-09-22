---
name: execute-reproduction
description: Run the reproduction - start services in labelled terminals, verify health and cluster formation, establish a baseline, execute the customer's steps exactly, and troubleshoot failures through the ten-rung ladder within a three-attempt budget. Enforces the safety check before any destructive operation. Use as stages 5-7 of a reproduction.
---

# Execute — run it

## Terminal model

Each long-running process gets its own labelled session. Label them and use the labels
consistently in `commands.log`:

```
[T1] EAP_NODE_1      [T2] EAP_NODE_2      [T3] EAP_NODE_3
[T4] LOAD_BALANCER   [T5] CLIENT          [T6] LOG_MONITOR
```

Two ways to run them; pick per environment:

- **Headless (default, and what CI uses):** background each process with output redirected
  to `logs/<label>.log`, record the PID to `<label>.pid`. Works everywhere, keeps the log
  as an artifact.
- **Visible terminals:** launch each node in its own terminal window when the user is
  watching interactively. Terminal emulators launched over D-Bus do **not** inherit the
  caller's environment, so pass `JAVA_HOME`, `*_HOME` and every other variable explicitly on
  the command line rather than relying on the export.

Always support the headless path — a reproducer that only runs with a desktop session is
not portable.

## Command log

Every command against the reproduction environment, appended to `$PKG/commands.log`:

```
[2026-09-15T12:41:03+02:00] [T1] EAP_NODE_1
COMMAND: $EAP_HOME/bin/standalone.sh -c standalone-ha.xml \
         -Djboss.server.base.dir=$PKG/standalone-node1 \
         -Djboss.node.name=node1 -Djboss.socket.binding.port-offset=0
RESULT:  started
PID:     12345
LOG:     logs/node1.log
```

Failures are logged the same way, with the exit status and the relevant stderr. The log is
the replay record — an omitted failed command makes the run unreproducible.

## Safety check

Before **any** destructive operation — `rm -rf`, `kill`/`pkill`, `shutdown`, `reboot`,
firewall changes, network disruption, disk or database modification — confirm the target
belongs to this reproduction. See `reference/safety-rules.md`.

Short form: the target's path must be inside `$PKG` or a verified product install in the
lab, and the PID must be one this run recorded in a `.pid` file. A PID you did not start is
never a valid kill target. `pkill -f java` is never acceptable — it kills the user's IDE.

## Startup and health gates

Do not proceed past a red gate.

**1. Processes up.** PID alive, port listening (`ss -tlnp`). A process that started and
exited leaves a listening-port check failing — check the port, not just the PID.

**2. Boot clean.** Grep each node's log for boot errors and for the started-successfully
milestone. A server that reports startup *with errors* is a gate failure — read them.

**3. Cluster formed.** Every node's view must list every other node. Parse the membership
view from each node's own log and compare. Three nodes each reporting a view of one is
three clusters, not one — and every clustering symptom downstream will be a harness
artifact. Fix discovery before continuing.

**4. Application answering.** Call the endpoint. HTTP 200 with the expected body. Do not
accept "deployed" from the management API as proof — a WAR built against the wrong servlet
namespace deploys cleanly and 404s on every request.

**5. Load balancer.** Routes to every backend; sticky if the case needs stickiness. Verify
by observing which node serves successive requests, not by reading the config you wrote.

Capture all five into `evidence/before/`.

## Baseline

Prove the feature works before breaking it. Session created on node1 is readable from
node2. Cache entry written to one server reads back from another. The request succeeds, the
handshake completes.

**A failing baseline is a harness fault, always.** Fix it and restart. Everything after
this point is interpreted relative to the baseline; without one there is no verdict in
either direction.

Record the baseline in `evidence/before/baseline.txt` with the actual request/response.

## The customer's steps

Run them **exactly as written**, in their order, including steps that look irrelevant —
the irrelevant-looking step is often the one that matters.

If a step cannot be run as written, do not substitute silently. Record in `commands.log`
and `configuration-diff.txt` what was asked, what you did instead, and why.

Timestamp each step and capture state around it into `evidence/during/`.

For the failure injection itself — the kill, the restart, the network freeze — match the
case. "Node crashed" is `kill -9`; "node was restarted" is a graceful shutdown; "the
network went away" is neither, and killing a process to simulate it produces a clean
connection close that the product detects immediately, which is the opposite of what the
customer saw. Simulate silence with silence.

Confirm the injection actually took effect before measuring its consequences — the process
is really gone, the port is really closed, the traffic is really blocked.

**Intermittent issues:** repeat. Report `N/M` and the hit rate. One green run against an
intermittent bug is BLOCKED, not NOT REPRODUCED.

## When it does not reproduce

Walk the ladder in order; each rung is cheap and rules out a class of harness fault:

1. environment — right host, right resources, right OS
2. product installation — right version, install intact, reading the config you think
3. configuration — the generated file is the one actually loaded; check the boot log
4. dependencies — app, datasource, external services present
5. ports — no collisions, no stale listener from a previous run
6. networking — nodes can reach each other on the discovery and transport ports
7. startup — no errors during boot, all subsystems up
8. application — deployed *and answering*, `<distributable/>` where required
9. customer steps — executed as written, in order, with the right failure injection
10. logs — compare the reproducer's log against the customer's; which of their messages
    are missing, and which of yours do they not have?

Step 10 is usually decisive: the customer's log lines are the ground truth for whether you
built the same situation.

Then fix and retry. **Three attempts.** After the third, stop and report the blocker with
what each rung showed. Say plainly whether the conclusion is "the product did not
misbehave" or "my harness could not create the conditions" — they are completely different
answers for the customer.

## Version-specific issues

If the case points at a specific build, test the neighbours rather than reasoning about
them (spec §14). Change one variable at a time — product version, or JDK, never both — and
record each result. Report the boundary as an observation:

```
7.4.23 → ISSUE PRESENT
7.4.24 → ISSUE PRESENT
7.4.25 → ISSUE NOT PRESENT
→ boundary between 7.4.24 and 7.4.25
```

A boundary is where behavior changed in *your test*. Do not assert a cause, a fix, or a bug
ID for it unless you have a source that states it.
