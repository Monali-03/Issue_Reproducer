---
name: classify-and-report
description: Turn a completed reproduction run into a verdict and a deliverable - classify as REPRODUCED/PARTIAL/NOT REPRODUCED/BLOCKED against the pre-declared success criterion, run differential version testing where relevant, write the root-cause analysis without overclaiming, generate README/issue-summary/commands.log/configuration-diff, and package the tar.gz. Use as stages 9-10 of a reproduction.
---

# Classify and report

## The verdict

Judge against the success criterion written in `reproduction-plan.md` **before** the run.
If you find yourself deciding now what would have counted, the run was not controlled —
say so and re-run with a stated criterion.

| Verdict | Requires |
|---|---|
| **REPRODUCED** | Passing baseline, customer's steps executed as written, the criterion met, evidence at a citable path |
| **PARTIALLY REPRODUCED** | Same general behavior, some detail differs — and you name the detail |
| **NOT REPRODUCED** | Everything ran correctly, baseline passed, the behavior did not occur |
| **BLOCKED** | Could not execute: missing build, missing artifact, missing information, harness never worked |

Three-valued counting inside a repeated run: a clean success, a clean failure, and
**inconclusive**. Anything that is neither the expected-good nor the expected-bad outcome —
an auth error, a node that would not die, a failed write, a connection refused — is
inconclusive and counted as neither. Folding inconclusive runs into the failure bucket is
the single most common way a tool reports a bug that is not there.

Report intermittent results as `hit rate N/M (K inconclusive)`.

Three things that are **never** REPRODUCED:

- a failure that only happened because the cluster never formed,
- a failure of the harness, the test app, or the credentials,
- a version other than the customer's behaving badly — that is a finding about your
  version, and you must say which one you ran.

Send the claim to the `repro-verifier` subagent before publishing anything but BLOCKED.

## Differential testing (spec §14)

When the issue looks version-specific, test rather than reason. One variable at a time:

```
EAP 7.4.23 → ISSUE PRESENT      JDK 11 → reproduced
EAP 7.4.24 → ISSUE PRESENT      JDK 17 → not reproduced
EAP 7.4.25 → ISSUE NOT PRESENT  JDK 21 → not reproduced
→ behavior changed between 7.4.24 and 7.4.25
```

That is a boundary observed in this lab, not a root cause and not a fix confirmation. Do
not name a bug ID, a commit, or a release note unless you have read it — cite the source if
you have, and write NOT PROVIDED if you have not.

If the customer's exact version could not be tested, no conclusion about it is supportable
in either direction. Say that instead of extrapolating from the neighbour you did test.

## Root-cause analysis (spec §16)

```
Issue:
Reproduced:              YES / PARTIAL / NO / BLOCKED
Evidence:                <paths + the decisive quoted lines>
Observed behavior:
Expected behavior:
Likely cause:            <hypothesis, labelled as hypothesis>
Supporting evidence:
Contradicting evidence:  <what does not fit — omitting this is how a wrong theory ships>
Potential product defect:        YES / NO / UNKNOWN
Potential configuration issue:   YES / NO / UNKNOWN
Potential environment issue:     YES / NO / UNKNOWN
```

A hypothesis is presented as a hypothesis. Three UNKNOWNs is an honest answer when the
evidence does not separate them; picking one to look decisive is not.

## Artifacts

Generate into `$PKG/`, from `templates/report/`:

| File | Content |
|---|---|
| `README.md` | The 12 sections below |
| `issue-summary.md` | From intake, with the verdict appended |
| `environment.txt` | From discovery |
| `commands.log` | Every command, timestamped — accumulated during the run |
| `reproduction.log` | Narrative: what was done, when, what happened |
| `configuration-diff.txt` | Every customer-vs-reproducer deviation |
| `evidence/MANIFEST.txt` | Checksummed index |

README sections, in order: Environment · Product version · JDK · Prerequisites · Setup ·
Start · Reproduce · Expected result · Actual result · Logs · Configuration · Cleanup.

Lead the README with the **Requirements & Gap Analysis** checklist:

```markdown
## Requirements & gap analysis
| Requirement | Status | Impact if unmet |
|---|---|---|
| EAP 7.4.23 binaries | ✅ present at <path> | — |
| Customer's heap dump | ❌ not provided | cannot confirm the retained-set theory |
| Three physical hosts | ⚠️ substituted loopback | no real partition testing |

Confidence in this reproduction: <high/medium/low> — <one sentence why>
```

Only genuinely irreducible items belong there — the exact micro-version, customer dumps,
customer workload, a customer directory server. If you could have bundled it yourself (a
load balancer, a load generator, a test app), bundle it instead of listing it.

## Packaging

```bash
cd output && tar czf "issue-reproducer-<product>-<version>.tar.gz" "<case-id>"
sha256sum "issue-reproducer-<product>-<version>.tar.gz"
```

Before packaging, verify the package stands alone: scripts executable, no absolute paths
from this host baked into them, `nodes.env` holding every tunable, no credentials in any
file, and the README's commands matching the scripts that actually exist.

## Final response (spec §22)

Emit exactly this, filled from the package:

```
==================================================
ISSUE REPRODUCER RESULT
==================================================

Product:
Version:
JDK:
OS:

Environment:

Reproduction status:
REPRODUCED / PARTIAL / NOT REPRODUCED / BLOCKED

==================================================
CUSTOMER ISSUE
==================================================

==================================================
REPRODUCTION STEPS
==================================================

1.
2.
3.

==================================================
RESULT
==================================================

Expected:

Actual:

==================================================
EVIDENCE
==================================================

Logs:

Error:

Configuration:

==================================================
ANALYSIS
==================================================

==================================================
GENERATED FILES
==================================================

==================================================
NEXT ACTION
==================================================
```

`NEXT ACTION` is a concrete next step — the artifact to request from the customer, the
version to test next, the escalation to raise — not a summary of what you just did.
