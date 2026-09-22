# Measurement plans

A measurement plan is how this reproducer handles a case it has never seen. Instead of a
scenario function per issue shape, a plan says three things:

* **probes** — what to observe, taken once before the fault and once after it
* **a fault** — what to change between the two observations
* **a criterion** — what reading counts as the customer's symptom, written down *before*
  the fault is injected

The six hand-written paths (cluster formation, session failover, deployment, the Data Grid
cache path, and the three JVM workloads) are unchanged and still take priority. A plan is
what runs when none of them fits — or, if you supply `input/plan.env`, instead of them.

## Preview one without running anything

```bash
./tools/show-plan.sh cases/eap7/E7-02-datasource-pool-exhausted/case.txt 2
```

It prints the plan the case would get. Read it before committing to a run: if the criterion
is not the customer's symptom, the verdict will not be about the customer's issue.

## Writing `input/plan.env`

Drop the file in the workspace's `input/` next to `case.txt`. It is sourced by the run, so
it is plain bash and it **outranks the detected scenario** — the case is authoritative and
a plan is the case stated precisely.

```bash
# input/plan.env — EAP datasource pool exhaustion

plan_symptom "Pool reaches max, threads park in the blocking wait, IJ000453 in the log, and
              it never recovers until restart."

# What to watch.
plan_probe pool-in-use   mgmt_attr /subsystem=datasources/data-source=ExampleDS/statistics=pool InUseCount
plan_probe pool-waiting  mgmt_attr /subsystem=datasources/data-source=ExampleDS/statistics=pool WaitCount
plan_probe timeouts      log_count 'IJ000453'
plan_probe app           http_status "http://127.0.0.1:8080/repro/info"

# The harness must show the good state first, or nothing after the fault is attributable.
plan_baseline_require app eq 200 "The application never served a request before the load started."

# What to change.
plan_fault load "http://127.0.0.1:8080/repro/jdbc" 40 100

# What counts as the symptom. Written here, read in the package in this order.
plan_criterion timeouts     increased
plan_criterion pool-waiting gt 0
```

### Probes

| kind | arguments | returns |
|---|---|---|
| `http_status` | `<url> [curl args...]` | the status code, or `UNKNOWN` if nothing answered |
| `http_match` | `<url> <regex> [curl args...]` | `yes` / `no` / `UNKNOWN` |
| `log_count` | `<regex>` | occurrences across this run's own server logs |
| `cluster_view` | `<node-index>` | members in that node's newest view |
| `mgmt_attr` | `<address> <attribute> [node-index]` | the attribute value via jboss-cli |
| `tls_handshake` | `<host> <port> [tls1_2\|tls1_3]` | `ok` / `fail` / `UNKNOWN` |
| `thread_deadlock` | `<argv-marker\|pid>` | number of Java-level deadlocks |
| `heap_used_after_gc` | `<argv-marker\|pid>` | KB still used after a forced full GC |
| `port` | `<host> <port>` | `open` / `closed` |

The extra curl arguments on the HTTP probes exist for authentication. Data Grid's properties
realm stores hashed credentials, so a probe against it needs `--digest -u user:pass`; a Basic
probe gets 401 and would report it as a product finding.

`log_count` reads only the logs *this run* produced — never `issue.txt`, never the customer's
attached logs. Counting the customer's own log file would reproduce every case instantly.

### Faults

| kind | arguments | notes |
|---|---|---|
| `none` | — | the customer's configuration is itself the fault; nothing to inject |
| `kill_node` | `<index>` | SIGTERM, escalate to SIGKILL, wait for the survivors to notice |
| `load` | `<url> [concurrency] [requests-each] [curl args...]` | fails if every request got no response |
| `redeploy` | `[cycles] [node-index]` | classloader-leak and metaspace cases |
| `wait` | `<seconds>` | timer-triggered cases; capped at 1800s |
| `cli` | `<jboss-cli command> [node-index]` | one runtime change through the management API |

`none` is a real answer, not a placeholder. A bad keystore, a `javax` WAR on EAP 8, a cache
with `owners: 1` — in all of those the fault is already present at boot and the measurement
is "start it as configured and look".

### Criteria

`plan_criterion <probe-id> <op> [value] [group]`

Operators: `eq` `ne` `gt` `ge` `lt` `le` `contains` `not_contains` `changed` `unchanged`
`increased` `decreased` `increased_by` `decreased_by`.

Criteria in the same **group** are OR'd; groups are AND'd; an ungrouped criterion stands
alone. Group when the case quotes several symptoms of one failure — three exception classes
from one incident is a description, not a promise that all three will be logged again.

Note that `increased`, `changed` and friends take no value, so the group is still the
**fourth** argument: `plan_criterion timeouts increased "" error-signature`.

### Baseline requirements

`plan_baseline_require <probe-id> <op> <value> <why it means the harness is broken>`

Checked against the *before* reading. A failure is `BLOCKED` (exit 4), never a negative
verdict — if the lab cannot demonstrate the working state, the broken state proves nothing
about the product.

## How a verdict comes out

```
any criterion group undecidable  ->  INCONCLUSIVE
the fault failed to inject       ->  INCONCLUSIVE  (and a deviation is recorded)
a baseline requirement failed    ->  BLOCKED, exit 4
every group holds                ->  REPRODUCED
otherwise                        ->  NOT REPRODUCED
```

A probe that could not be taken returns `UNKNOWN`, and `UNKNOWN` never becomes a negative.
"The product is fine" and "we failed to measure" are different statements, and only one of
them is worth sending to a customer.

## What the derived plan can and cannot do

With no `plan.env`, a plan is derived from what the case states: the error codes it quotes,
an HTTP status it quotes in an HTTP context, and whether its own steps kill a node, redeploy,
or apply load. That is deliberately shallow — it reads what the customer wrote down and does
not decide what they meant.

Two things it will not do:

* It will not build a criterion out of a code a healthy server logs anyway. `WFLYSRV0010`
  ("Deployed"), `WFLYCLJG0033` and `ISPN000094` are counted and kept in the package, but a
  run cannot be called REPRODUCED because a healthy server logged them. See
  `PLAN_BENIGN_CODES` in `lib/plan.sh`.
* It will not invent a criterion for a case whose symptom is not stated measurably. Those
  produce no plan and fall through to the log-signature reading, which can only tell you
  whether the case's error text turned up in this run.

The fix for both is the same: write `input/plan.env`.

## Self-test

```bash
./tools/selftest-measure.sh
```

Exercises the comparison table and the verdict logic against fabricated readings — no
product required. It is the guard on the two properties that would be dangerous to break:
the operators, and UNKNOWN never producing a negative verdict.
