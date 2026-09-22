# Reproducer — <PRODUCT> <VERSION> — <CASE-ID>

<one-line statement of the customer's issue>

**Reproduction status: REPRODUCED | PARTIALLY REPRODUCED | NOT REPRODUCED | BLOCKED**
<hit rate N/M if the issue is intermittent, with the inconclusive count>

---

## Requirements & gap analysis

Read this first. It says what this package proves and what it cannot.

| Requirement | Status | Impact if unmet |
|---|---|---|
| <PRODUCT> <VERSION> binaries | ✅ present at `<path>` | — |
| JDK <N> | ✅ `<path>` | — |
| Customer's exact CP level | ❌ tested <actual> instead | verdict applies to <actual>, not <claimed> |
| Customer heap dump | ❌ not provided | cannot confirm the retained-set theory |
| Three physical hosts | ⚠️ substituted loopback | no real network-partition testing |

**Confidence: <high | medium | low>** — <one sentence saying why>

Only irreducible items belong in this table. Anything that could have been bundled into
the package was bundled.

---

## 1. Environment

| | Customer | Reproducer |
|---|---|---|
| OS | | |
| Arch | | |
| Nodes | | |
| Mode | | |
| Load balancer | | |

Full inventory: `environment.txt`. Every deviation: `configuration-diff.txt`.

## 2. Product version

Claimed in the case: `<x.y.z>`
Verified from the boot banner: `<x.y.z>`
<state the mismatch prominently if there is one — it can decide the case>

## 3. JDK

`<vendor> <version>` at `<path>`. Supported for this product version: <yes/no/unverified,
with the source>.

## 4. Prerequisites

- <PRODUCT> <VERSION> installed; set `EAP_HOME` in `nodes.env`, or let `setup.sh` find it
- JDK <N>; set `JAVA_HOME` in `nodes.env`, or let `setup.sh` find it
- <maven / httpd / podman / oc, as applicable>
- Ports <list> free on <bind address>

## 5. Setup

```bash
./scripts/setup.sh
```

Resolves the JDK and the product home, seeds a separate server base directory per node,
builds the test application, applies the case configuration. Idempotent.

## 6. Start

```bash
./scripts/start.sh              # headless
./scripts/start.sh --terminals  # one visible terminal per node
```

Starts every node and the load balancer, then enforces five gates: ports listening, clean
boot, **cluster formed with every node in every view**, application endpoint answering 200,
load balancer routing and sticky. Any failed gate exits non-zero — the harness is wrong and
no verdict from it would mean anything.

## 7. Reproduce

```bash
./scripts/reproduce.sh
./scripts/reproduce.sh --repeat 10    # intermittent issues
```

Establishes the baseline, injects the customer's failure, measures against the success
criterion declared in `reproduction-plan.md`. Reports reproduced / not reproduced /
inconclusive.

The customer's steps, as executed:

1. <verbatim from the case>
2.
3.

## 8. Expected result

<what the customer expects, in their words>

## 9. Actual result

<what this reproduction observed, with the decisive evidence quoted>

```
<log lines / HTTP responses, verbatim, with their source path>
```

## 10. Logs

| Path | Content |
|---|---|
| `logs/nodeN.log` | per-node console output |
| `evidence/before/` | pre-injection state and the passing baseline |
| `evidence/during/` | injection timeline and live state |
| `evidence/after/` | post-injection state, logs, cluster view |
| `evidence/*/MANIFEST.txt` | checksummed index of every artifact |
| `commands.log` | every command run, timestamped, with exit status |
| `reproduction.log` | narrative run log |

## 11. Configuration

| Path | Purpose |
|---|---|
| `nodes.env` | topology and paths — the only file to edit when relocating |
| `config/eap/` | per-node server configuration and CLI scripts |
| `config/jgroups/` | discovery and transport stack |
| `config/lb/` | load balancer |
| `config/customer-configs/` | the customer's own files, for reference — not applied |
| `configuration-diff.txt` | every customer-vs-reproducer deviation, with impact |

## 12. Cleanup

```bash
./scripts/cleanup.sh            # stop processes
./scripts/cleanup.sh --purge    # also remove node state and logs; evidence survives
```

---

## Analysis

**Likely cause:** <hypothesis, labelled as a hypothesis>
**Supporting evidence:** <paths and quoted lines>
**Contradicting evidence:** <what does not fit — omitting this is how a wrong theory ships>

| | |
|---|---|
| Potential product defect | YES / NO / UNKNOWN |
| Potential configuration issue | YES / NO / UNKNOWN |
| Potential environment issue | YES / NO / UNKNOWN |

## Next action

<the concrete next step: the artifact to request, the version to test, the escalation to
raise — not a summary of what was done>
