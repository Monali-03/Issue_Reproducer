# datagrid — Red Hat Data Grid / Infinispan server reproducer

Reproduces customer issues against a **Red Hat Data Grid 8.x server** installation. This
workspace reads only its own `input/` and writes only its own `output/`. It will refuse an
EAP or JDK case outright rather than run it against the wrong product.

## 1. Drop the case in

```
workspaces/datagrid/input/
├── case.txt            ← the customer's scenario (REQUIRED)
├── configs/            ← infinispan.xml, cache JSON definitions, *.properties
├── logs/               ← server.log, console output
├── dumps/              ← thread dumps, heap dumps
└── attachments/        ← anything else they sent
```

`input/case.txt` is a filled-in copy of `templates/case.txt`. Two lines decide everything
and are not optional:

```
Product: Red Hat Data Grid
Version: 8.5.2
```

Two customer artifacts are picked up automatically if you supply them:

- `input/configs/infinispan*.xml` — becomes `conf/infinispan.xml` on every node, verbatim.
- any `*cache*.json` in `configs/` or `attachments/` — used as the cache definition instead
  of the bundled one. Reproducing against the customer's own cache mode, owner count and
  encoding is usually the whole ball game.

## 2. Run it

```bash
cd workspaces/datagrid
./run.sh
```

| flag | effect |
|---|---|
| `--nodes N` | override the node count detected from the case |
| `--scenario NAME` | override scenario detection |
| `--keep-running` | leave the servers up afterwards so you can poke at them |
| `--clean` | kill anything this workspace left running, then exit |

The run discovers the Data Grid installation, seeds one isolated server root per node,
overlays TCPPING discovery, **creates the REST user**, starts the cluster, then drives the
bundled cache harness: create the cache, write a known set of entries, read **every one
back from every node**, kill a node, and read them all again.

### Prerequisites

A Data Grid 8.x **server** distribution and a JDK have to be on the host already — neither
is shipped here. Download `redhat-datagrid-8.x-server.zip` from the Customer Portal (the
**server** distribution, not the library or the operator), unpack it anywhere you like,
install a JDK (`sudo dnf install java-17-openjdk-devel`), and name both:

```bash
export RHDG_HOME=/opt/labs/redhat-datagrid-8.5.2-server   # the directory holding bin/server.sh
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
./run.sh
```

Leave `RHDG_HOME` unset and the workspace searches `~/Documents/Datagrid/redhat-datagrid-*-server`,
`~/Documents/EAP_lab/redhat-datagrid-*-server`, `/opt/redhat-datagrid-*-server` and
`~/infinispan-server-*` instead. `JAVA_HOME` is used only when its major matches the JDK the
case names; the default is 17. If either is missing the run ends `BLOCKED` with the paths it
tried. Full details in the repository README.

## 3. What comes out

`output/<case>-<timestamp>/`, with `output/latest` pointing at the most recent run:

| file | what it is |
|---|---|
| `VERDICT.txt` | REPRODUCED / NOT REPRODUCED / INCONCLUSIVE / BLOCKED, and why |
| `SOLUTION.md` | ranked candidate causes, each with a check command and a fix |
| `README.md` | the run written up, in the order someone else would re-run it |
| `reproduction.log` / `commands.log` | everything printed / every command with its exit status |
| `configuration-diff.txt` | every way the lab differs from the customer's environment |
| `logs/` | each node's `server.log` and console output |
| `config/` | the `infinispan.xml` each node booted with |
| `evidence/before/` | cluster view per node, cluster members over REST, the baseline verify report |
| `evidence/during/` | the post-kill verify report — per node, `hits` / `misses` / `errors` |
| `app/cache-harness.sh` | the harness itself, re-runnable by hand against `nodes.env` |
| `../<case>-<timestamp>.tar.gz` | the package minus `nodes/` and heap dumps — this is what you attach |

## Ports it uses

single-port endpoint `13222 13322 13422` · JGroups `9800 9900 10000`.

Disjoint from eap7 and eap8, so all three can run at the same time. Each workspace also
takes its own `.run.lock`, which stops two runs of *this* workspace from colliding.

## What it will not do

- **It will not run another product's case.** An EAP or JDK case in this folder is a hard
  error naming the folder it belongs in.
- **It will not guess.** Anything the case does not state is marked `INFERRED` with its
  derivation, or `NOT PROVIDED`. No bug IDs, KB numbers or "fixed in" claims are ever
  emitted.
- **It will not report a reproduction it cannot show.** Four gates (port listening →
  server started → cluster formed in every node's view → the *authenticated* cache API
  answers) and a passing baseline run before the node is killed.

## Notes specific to Data Grid

- **Auth is digest, not Basic.** The properties realm stores hashed credentials, so Basic
  is rejected even with the right password. `/health/status` answers *anonymously*, which
  is why a readiness probe against it reports HEALTHY while every real call 403s — gate 4
  deliberately calls `/rest/v2/caches` with `--digest` instead.
- The harness counts three outcomes — `hits`, `misses`, **`errors`** — never two. A 403 or
  a connection refusal is an error, not a missing entry; collapsing the two is how a
  replication bug gets reported that does not exist.
- The `-o` offset covers the server's socket bindings but **not** the JGroups bind port,
  which is set separately per node via `-Djgroups.bind.port`.
- Set `DG_SKIP_TCPPING=1` only if the environment genuinely has working multicast.
