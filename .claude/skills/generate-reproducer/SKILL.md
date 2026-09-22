---
name: generate-reproducer
description: Build the reproduction plan and then generate every artifact it needs - per-node server configs, JGroups/Infinispan stacks, JVM options, load balancer config, test application, container/OpenShift manifests, and the setup/start/reproduce/collect/cleanup scripts - plus the customer-vs-reproducer configuration diff. Use as stages 3-4 of a reproduction, or standalone to scaffold a lab from a topology description.
---

# Generate — plan and build the reproducer

Two halves. Plan first, show it, then build.

## Half 1 — the plan

Write `$PKG/reproduction-plan.md`:

```markdown
# Reproduction plan — <case id>

## Target
Product / Version (+CP) / JDK / OS / Mode / Distribution

## Topology
              Load balancer (httpd mod_proxy, :8090, sticky)
                        |
        +---------------+---------------+
        |               |               |
      EAP-1           EAP-2           EAP-3
   127.0.0.1:8080  127.0.0.1:8180  127.0.0.1:8280
   jgroups :7600   jgroups :7700   jgroups :7800
   base: standalone-node1 / node2 / node3

## Resources
Machines/containers | product installs | JDK | ports (full list) | disk | memory

## Configuration to generate
<file → purpose → derived from>

## Application
<what it does, why it is sufficient to exercise the reported path>

## Reproduction steps (from the case)
1. <verbatim>

## Expected / Observed (per the customer)

## Success criteria
<the precise, checkable condition that makes this REPRODUCED —
 e.g. "GET /app/session after node1 kill returns a counter of 0 or a new JSESSIONID">

## Gap analysis
| Need | Have | Impact | Confidence |
```

Define the **success criterion before running**. Deciding afterwards what counts as the bug
is how a harness failure gets reported as a reproduction.

Show the plan to the user before building.

## Half 2 — generation

Everything lands under `$PKG/`. Nothing is written into the product installation.

### Per-node isolation — the rule that decides whether a cluster works

Each node gets its **own server base directory**, not just a port offset. Sharing a base
means the instances fight over `data/`, `tmp/`, `log/` and deployment markers, and the
resulting failures look like product bugs.

For EAP: seed `standalone-nodeN` from the stock `standalone/` directory and pass
`-Djboss.server.base.dir=<...>` alongside the port offset and `-Djboss.node.name=<...>`.
For Data Grid: give each server its own `-s <server-root>`.

Never modify the shared installation. If a node needs a changed config, copy it into the
node's own base directory first.

### Per-node configuration

Nodes that need different configuration get different files (spec §19). Discovery lists,
node names, bind addresses and ports are per-node. Generating three identical files when
the topology requires distinct ones is a defect.

Preserve the customer's topology shape. If they list three hosts with a static discovery
list, the reproducer has three nodes with a static discovery list — remapped to lab
addresses, with the remapping recorded in the config diff.

### Addresses and ports

No hard-coded IPs in scripts. One `nodes.env` holds the topology; every script sources it:

```bash
EAP_HOME=   JAVA_HOME=   LB_PORT=
# name  http_port  mgmt_port  jgroups_port  base_dir
NODES=(
  "node1 8080 9990  7600 standalone-node1"
  "node2 8180 10090 7700 standalone-node2"
)
```

### Schema fidelity

Read the namespace from the target installation's own stock config and use that. Never
copy a config from a different release — subsystem schemas change between majors and often
between minors, and a wrong namespace fails at boot in a way that has nothing to do with
the customer's issue.

When layering a change onto a stock config, prefer the product's own mechanism — a CLI
script (`jboss-cli.sh --file=`) or a config overlay — over hand-editing XML. It survives
version differences better and it documents the change.

### The test application

Bundle one. The reproduction must not depend on the customer shipping their WAR.

Build the smallest application that exercises the reported path — a session counter for
replication cases, a cache read/write endpoint for Data Grid, a TLS endpoint for handshake
cases. Match the servlet/Jakarta namespace to the product major version: `javax.*` and
`jakarta.*` are not interchangeable, and getting it wrong on a Jakarta-era server produces
a deployment that reports success while every endpoint 404s. Always verify by calling the
endpoint, never by reading deployment status.

For clustering, `<distributable/>` in `web.xml` is what makes the session replicate —
if the case is about replication, its presence or absence is part of the reproduction.

### Load balancer

If the case involves failover, bundle the balancer. Configure stickiness explicitly and
make the backend routing observable — you need to know which node served each request, or
you cannot tell failover from a request that never moved.

### Scripts

Generate all five from `templates/scripts/`. They must be idempotent, run from any
directory, source `nodes.env`, use `set -euo pipefail`, and log every command to
`commands.log`.

| Script | Contract |
|---|---|
| `setup.sh` | JDK + product resolution, node base dirs, build app, apply config. Re-runnable. |
| `start.sh` | Start all nodes + LB, wait for readiness, verify cluster view, verify endpoint |
| `reproduce.sh` | Baseline, then the customer's steps, `--repeat N` for intermittent cases, prints the verdict |
| `collect.sh` | Logs, dumps, cluster state, config snapshot into `evidence/` |
| `cleanup.sh` | Stop everything started here, by matching the actual server process, not the wrapper |

Shell traps that bite in exactly these scripts, all under `set -e`:

- `x="$(grep ... | tail -1)"` aborts the script when grep matches nothing — which is the
  normal case inside a wait loop. Append `|| true`.
- `grep -c` prints `0` **and** exits 1. Needs `|| true` and a `${n:-0}` default.
- `eval "$(cmd)"` does **not** propagate `cmd`'s failure. Capture, check `$?`, then eval.
- Killing by wrapper-script name orphans the JVM, which keeps serving and silently breaks
  the failover step. Match the server's own argv.

### Containers and OpenShift

When the case is containerized, generate the `Containerfile`, `compose.yaml` or the
`Deployment`/`StatefulSet` + `Service` + `Route` + `ConfigMap`/`Secret` manifests. Use a
StatefulSet with stable identities for clustered workloads, and the discovery protocol
appropriate to the platform (DNS/Kube-based, not multicast). Secrets are templates with
placeholders — never real credentials.

## Configuration diff — `$PKG/configuration-diff.txt`

Every deviation, one block each:

```
[1] JGroups discovery
CUSTOMER CONFIGURATION:   TCPPING, initial_hosts 10.0.22.85/86/87[7800]
REPRODUCER CONFIGURATION: TCPPING, initial_hosts 127.0.0.1[7600,7700,7800]
CHANGE:                   addresses remapped to loopback with distinct ports
REASON:                   single lab host; three routable addresses unavailable
FUNCTIONAL IMPACT:        none for discovery semantics; does not reproduce
                          network-partition behavior between physical hosts
```

Be honest in FUNCTIONAL IMPACT. "None" on a deviation that plausibly matters is the kind of
thing the verifier will catch and the customer will not.
