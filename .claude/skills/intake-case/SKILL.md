---
name: intake-case
description: Extract every reproducible field from a Red Hat customer case - product, version, patch level, JDK, OS, topology, ports, configs, steps, expected vs actual, errors - marking each as stated, INFERRED or UNKNOWN. Also ingests a case bundle directory of raw customer artifacts (configs, logs, thread dumps, attachments). Use as the first stage of a reproduction, or standalone to triage a case.
---

# Intake — case extraction

Turn free-form case text (and any attached artifacts) into a structured, honestly-labelled
set of facts. Everything downstream is built on this, so a guess here poisons the whole run.

## Where the input is

**`input/` is the default drop zone.** Look there first, always — the user puts the case
and the customer's artifacts there:

```
input/
├── case.txt          # the scenario
├── configs/          # standalone.xml, infinispan.xml, httpd.conf, jgroups stacks...
├── logs/             # server.log, boot.log, GC logs, httpd logs
├── dumps/            # thread dumps, .hprof
└── attachments/      # anything else, including the customer's own WAR/EAR
```

Also accepted: a case pasted directly into the conversation, or a path to another bundle
directory with the same shape (`input/<case-number>/` when several cases are kept side by
side).

If `input/case.txt` is still the unmodified template, say so and ask for the case rather
than reproducing the placeholder text.

Copy the case verbatim to `$PKG/issue.txt` first, and copy every artifact you actually used
into the package. The user's originals in `input/` are never modified — they reuse that
directory for the next case.

A customer WAR/EAR in `input/attachments/` is worth more than any bundled blueprint. Note
it for `build-test-app` and set `CUSTOMER_WAR` in `nodes.env`.

## Fields to extract

Emit every one of these. A field you did not find still appears, marked.

| Group | Fields |
|---|---|
| Product | product, version, patch/CP level, distribution (zip/RPM/container/Operator) |
| Runtime | JDK vendor + version, JVM options, system properties, env vars |
| Platform | OS + version, architecture, containerized, OpenShift/K8s + version |
| Topology | mode (standalone/domain/managed-domain), profile/config file, node count, node addresses, LB type (mod_cluster/mod_proxy/HAProxy/Route), site count for cross-site |
| Network | ports, protocols, bind addresses, discovery mechanism (MPING/TCPPING/JDBC_PING/DNS_PING/KUBE_PING), TLS in use |
| Application | deployment name and type, frameworks, whether `<distributable/>`, datasources, external dependencies (LDAP/AD, DB, message broker) |
| Behavior | customer steps (ordered, verbatim), expected behavior, actual behavior |
| Diagnostics | error messages verbatim, product message codes, stack traces, log excerpts, timestamps |

## Labelling — the core discipline

Three labels, and only three:

- **stated** — the case says it. Quote it.
- **INFERRED** — you derived it, and you write down what from.
  `JDK: OpenJDK 11 (INFERRED — stack trace frames show java.base/jdk.internal.* and the case says EAP 7.4 on RHEL 8)`
- **UNKNOWN** / **NOT PROVIDED** — you do not know. Leave it empty.

Never let a default masquerade as a fact. "Probably 8080" is UNKNOWN. "standalone-ha.xml
because the case mentions clustering" is a legitimate INFERRED with its reason attached.

When an INFERRED field would change the reproduction materially — a different major
version, a different discovery protocol, a different failover model — surface it to the
user rather than silently building on it.

## Version resolution

The case text is the customer's *claim* about their version. Artifacts beat claims:

1. **Boot banner** in `server.log` / `boot.log` — authoritative. Grep for the startup line
   carrying the product name and version.
2. **`$PRODUCT_HOME/version.txt`**, or the JBoss modules / product-conf metadata in the
   install.
3. Case text.

If 1 and 3 disagree, report the mismatch prominently — customers often report the version
they installed rather than the one they patched to, and the whole verdict can turn on it.

Then resolve, per `reference/version-matrix.md`:

- exact product version including CP/patch level,
- the supported JDK set for that version — **look it up, do not recall it**,
- the config schema namespace, read from the install's own XML,
- whether the issue is plausibly version-specific (a candidate for differential testing).

## Reading bundled artifacts

Do not paste artifacts into your context. Delegate:

```
Agent(subagent_type: "evidence-analyst",
      prompt: "Distil <bundle>/logs/server.log. I need: product version from the boot
               banner, all distinct ERROR/WARN with counts, all WFLY/ISPN/JGRP codes,
               exception chains, and the cluster view history.")
```

Run the log analysis, the dump analysis and the config reading concurrently — they are
independent.

Customer configs are copied into the package as `config/customer-configs/` and **never
applied automatically**. Generate a diff against the stock config for that exact release so
the reproducer's deviations from the customer's real setup stay visible.

Redact credentials, tokens, keys and certificates. Keep hostnames, IPs and ports.

## Gaps

Close with the questions you actually need answered, ranked by whether they block the
reproduction:

```
BLOCKING (cannot reproduce without):
- Exact CP level — case says "7.4" only; 7.4.0 and 7.4.23 differ materially here

NON-BLOCKING (would improve fidelity):
- Customer's JVM heap settings
```

Ask the blocking ones. Proceed on the rest with the gap recorded.

## Output — `$PKG/issue-summary.md`

```markdown
# Case <id> — <one-line title>

## Classification
Product / Version / Patch level / JDK / OS / Arch / Deployment / Mode / Platform

## Topology
<ASCII diagram, or UNKNOWN>

## Configuration
<per file: source, what it sets, whether it was provided>

## Customer steps
1. <verbatim>

## Expected
## Actual
## Errors and codes
<verbatim only — never reconstructed>

## Field table
| Field | Value | Source |
|---|---|---|
| Product | JBoss EAP | stated |
| Version | 7.4.23 | stated |
| JDK | OpenJDK 11 | INFERRED — <reason> |
| Node count | UNKNOWN | — |

## Gaps
BLOCKING / NON-BLOCKING

## Version-specific?
<yes + differential candidates | no | UNKNOWN>
```
