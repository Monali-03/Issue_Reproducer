---
name: reproduce-issue
description: Master pipeline for reproducing a Red Hat customer issue end to end - intake, environment discovery, planning, config generation, execution, evidence collection, verdict and packaging. Use when handed a customer case for JBoss EAP, JWS/Tomcat, JBCS/httpd, Data Grid/Infinispan, OpenJDK, JGroups, Elytron, clustering, session replication, TLS, or OpenShift, and the goal is to actually run the reproduction rather than describe it. Triggers on "reproduce this case", "can you reproduce", a pasted support case, or a case bundle directory.
---

# Reproduce Issue — master pipeline

Drives the full reproduction. Each stage is its own skill; this one sequences them, owns
the output package, and enforces the gates between stages.

**The deliverable is a reproduction that ran, with evidence. Not a procedure.**

## Before you start

Create the todo list so the user can see progress:

```
1. Intake — extract case fields, resolve versions
2. Discover — inventory the host
3. Plan — topology, versions, ports, gap analysis
4. Generate — configs, scripts, test app
5. Start — bring services up, verify health
6. Baseline — prove the feature works before breaking it
7. Execute — run the customer's steps
8. Evidence — before/during/after
9. Verdict — classify, verify adversarially
10. Package — artifacts + tar.gz
```

Then pick the case id and create the package skeleton:

```bash
CASE_ID="<case-number, or product-version-slug>"
PKG="output/$CASE_ID"
mkdir -p "$PKG"/{scripts,config/{eap,datagrid,jgroups,jvm,application,lb},app,logs,evidence/{before,during,after},output}
```

Copy the case in verbatim as `$PKG/issue.txt` before doing anything else. That file is
never edited afterwards — it is the record of what was actually asked.

## Stage 1 — Intake

`Skill(intake-case)`. Reads `input/` by default — `case.txt` plus `configs/`, `logs/`,
`dumps/`, `attachments/`.

**Gate:** you must know the product and a version before continuing. If the case does not
state them and the bundle has no boot banner to read them from, stop and ask the user. Do
not pick a plausible version — a reproduction against the wrong build answers nothing.

Everything else may proceed as INFERRED or UNKNOWN.

## Stage 2 — Discover

`Skill(discover-env)`. Writes `$PKG/environment.txt`.

**Gate:** the required product install must exist on this host, or be installable, or the
run is BLOCKED. Report the blocker now rather than after an hour of setup.

## Stage 3 — Plan

`Skill(generate-reproducer)`, planning half. Writes `$PKG/reproduction-plan.md` with the
ASCII topology, and `$PKG/configuration-diff.txt` seeded with every known deviation.

Show the user the plan and the gap analysis before you start building. This is the moment
to catch a wrong reading of the case — not after the cluster is up.

## Stage 4 — Generate

`Skill(generate-reproducer)`, generation half. Writes `config/`, `scripts/`.

Then `Skill(build-test-app)` for the application — **always build one**, don't ask the user
for a WAR. It picks the blueprint from the case: `session-cluster` for clustering and
failover, `cache-harness` for Data Grid server, `simple-web` for everything else. A
customer WAR in `input/attachments/` takes precedence over all three.

**Gate:** `./scripts/setup.sh` must complete clean. It is idempotent — re-run it.

## Stage 5 — Start

`Skill(execute-reproduction)`, startup half. `./scripts/start.sh`.

**Gate — do not skip this, it is where most false positives are born:**

- every process is up and the port is listening,
- the cluster has formed and **each node's view lists every other node** (one node seeing
  only itself is a harness fault, fix it before going on),
- the application is deployed *and its endpoint actually answers* — deployment status is
  not proof; call the URL,
- the load balancer routes to every backend, and is sticky if the case depends on it.

Capture all of this into `evidence/before/`.

## Stage 6 — Baseline

Prove the feature works **before** you break it, and prove it with data the harness wrote
itself — never by assuming a fresh cluster is empty-but-fine.

- **session-cluster:** create a session through the LB, increment it, confirm the counter
  and `sessionId` survive across requests and that a second node returns the same session.
- **cache-harness:** `cache-harness.sh create && put 100 && members && verify` — every
  entry readable from **every** node.
- **simple-web:** the endpoint returns 200 with the expected body on every node.

**Gate:** a failing baseline means the harness is wrong, not that the bug is reproduced.
Fix and restart. Without a passing baseline there is no negative result and no positive one
either — the whole verdict rests on this.

## Stage 7 — Execute

`Skill(execute-reproduction)`, reproduction half. `./scripts/reproduce.sh`.

Run the customer's steps **exactly as written**, in their order, including steps you believe
are irrelevant. If a step cannot be executed as written, record why in `commands.log` and
in the config diff — do not quietly substitute your own.

If the case describes an intermittent issue, repeat and report a hit rate (`N/M`). A single
run does not characterize an intermittent bug.

## Stage 8 — Evidence

`Skill(collect-evidence)`. `./scripts/collect.sh`. Fills `evidence/{before,during,after}/`.

## Stage 9 — Verdict

`Skill(classify-and-report)`.

Then, before publishing anything other than BLOCKED, send the claim to the verifier:

```
Agent(subagent_type: "repro-verifier",
      prompt: "Claimed verdict: <...>. Evidence: <abs path>/evidence.
               Config diff: <abs path>/configuration-diff.txt.
               Case: <abs path>/issue.txt. Rule on it.")
```

If it returns DOWNGRADE, downgrade — or go fix the harness defect it found and re-run from
Stage 5. Do not argue past it and publish the original claim.

## Stage 10 — Package

`Skill(classify-and-report)`, packaging half. Produces the README, `issue-summary.md`, and
`issue-reproducer-<product>-<version>.tar.gz`.

## Retry budget

Three attempts (spec §15). Walk the ladder — environment, installation, configuration,
dependencies, ports, networking, startup, application, customer steps, log comparison —
fix, retry. After the third failed attempt stop and report the blocker with what you tried
at each rung. Grinding past three attempts wastes the user's time and budget.

## Reporting

Close with the spec §22 block, from `classify-and-report`. Then state the gap analysis:
what the reproduction could not cover and what would be needed. Keep that list to genuinely
irreducible items — exact micro-version, customer dumps, customer workload, customer
directory server. Anything you could have bundled yourself does not belong on it.
