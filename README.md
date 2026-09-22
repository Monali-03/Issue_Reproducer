# Red Hat Issue Reproducer

Four self-contained product workspaces. You drop a customer case, their logs and their
configuration into the folder for that product, run one script, and get back a reproduction
package: the verdict, the logs and configs the run produced, the evidence behind the
verdict, and steps for how to solve the issue.

These are plain shell scripts. Nothing here calls out to an AI at runtime.

```
workspaces/
├── eap7/       JBoss EAP 7.x
├── eap8/       JBoss EAP 8.x
├── datagrid/   Red Hat Data Grid / Infinispan server 8.x
└── jvm/        OpenJDK / HotSpot
```

## Use it

First time on a machine, put the product binaries and a JDK where the run can find them —
see [Setup](#setup-where-to-put-the-binaries-and-the-jdks). Then:

```bash
cd workspaces/eap7          # or eap8, datagrid, jvm
$EDITOR input/case.txt      # the customer's scenario
cp ~/case-attachments/standalone-ha.xml input/configs/
cp ~/case-attachments/server.log         input/logs/
./run.sh
```

Then read `output/latest/VERDICT.txt` and `output/latest/SOLUTION.md`, and attach
`output/<case>-<timestamp>.tar.gz` to the case.

Each workspace has its own `README.md` with the details that only apply to that product.
Start there.

## The four workspaces do not interfere with each other

This is structural, not a convention:

| | reads | writes | endpoint ports | management | JGroups |
|---|---|---|---|---|---|
| `eap7` | `workspaces/eap7/input/` | `workspaces/eap7/output/` | 8080 8180 8280 | 9990 10090 10190 | 7600 7700 7800 |
| `eap8` | `workspaces/eap8/input/` | `workspaces/eap8/output/` | 9080 9180 9280 | 10990 11090 11190 | 8600 8700 8800 |
| `datagrid` | `workspaces/datagrid/input/` | `workspaces/datagrid/output/` | 13222 13322 13422 | — | 9800 9900 10000 |
| `jvm` | `workspaces/jvm/input/` | `workspaces/jvm/output/` | none | — | none |

- **No workspace ever reads another workspace's `input/`.** The path is derived from the
  script's own location; there is no configuration that could point it elsewhere.
- **A case in the wrong folder is refused,** not run badly. Each workspace declares which
  products it accepts, which it explicitly excludes, and which major version it is for. A
  Data Grid case dropped into `eap7/` exits with an error naming the folder it belongs in —
  the exclusion is checked before the match, so "Red Hat JBoss Data Grid 7.3" cannot
  satisfy a loose EAP pattern and get run as an application server.
- **The port blocks are disjoint**, and each workspace takes its own `.run.lock`. Running
  `eap7` and `datagrid` at the same time is a supported thing to do; it has been verified.
- **`./run.sh --clean` only signals processes whose command line points into *this*
  workspace's `output/` tree.** It cannot touch another workspace, or anything else on the
  machine.

## What a run actually does

1. **Reads the case** and refuses it if it belongs to another product, or if `case.txt` is
   still the unmodified template.
2. **Picks a scenario** from the wording of the case — session-failover, clustering, cache,
   cross-site, deadlock, memory, cpu-gc, tls, datasource, deployment, or generic.
3. **Finds the product installation and a JDK** on this host, reading the version from the
   installation's own banner rather than from its directory name.
4. **Plans ports and seeds one isolated tree per node.** Per-node `jboss.server.base.dir`,
   not just a port offset — sharing `data/`, `tmp/` and deployment markers between
   instances produces failures that look exactly like the customer's.
5. **Builds the test application itself.** A clustered, `<distributable/>` WAR for
   clustering and failover cases, a plain one otherwise, a REST cache harness for Data Grid.
   A customer WAR in `input/attachments/` wins over all of them.
6. **Starts everything and runs the gates** (five for EAP, four for Data Grid). Ports
   listening → clean boot → cluster formed in *every* node's view → the endpoint actually
   returns 200 → routing. If a gate fails the run exits **BLOCKED**, because a lab that is
   already broken reproduces every symptom you point it at.
7. **Establishes a passing baseline** before injecting anything: the session replicates,
   or every cache entry is readable from every node.
8. **Injects the failure** — kills a node by a recorded PID whose argv is re-checked first —
   and measures.
9. **Writes the package.**

## What comes out

```
output/<case>-<timestamp>/
├── VERDICT.txt             REPRODUCED / NOT REPRODUCED / INCONCLUSIVE / BLOCKED, and why
├── SOLUTION.md             how to solve it: ranked causes, each with a check and a fix
├── README.md               the run written up, in re-run order
├── issue-summary.md        what the case stated, what was inferred, what was unknown
├── configuration-diff.txt  every way the lab differs from the customer's environment
├── reproduction.log        everything the run printed
├── commands.log            every external command, with its exit status
├── environment.txt         host, JDK, product version, ports
├── MANIFEST.txt            sha256 of every file in the package
├── config/  logs/  app/  nodes/  scripts/
└── evidence/before/ during/ after/
output/<case>-<timestamp>.tar.gz     the same, minus nodes/ and *.hprof
output/latest -> the most recent run
```

`SOLUTION.md` is generated from the symptom the run **observed**, not from the case text.
Every entry carries a check that tells you whether it applies to the customer, and a fix.
It contains no bug IDs, KB numbers or "fixed in" claims: those have to come from the
Customer Portal, and a remembered one is worse than none.

## The rules these scripts hold themselves to

**Run it.** Explaining how an issue could be reproduced is not the deliverable. A verdict
with evidence is.

**Never guess.** No invented error messages, configuration values, version behaviour, stack
traces, topology, addresses, or bug IDs. Everything is labelled `stated`, `INFERRED` with
its derivation, or `NOT PROVIDED`. Product facts come from the installation in front of the
script.

**Verify the harness before trusting the verdict.** Most false reproductions are the harness
failing, not the product: the cluster never formed, the WAR deployed cleanly and 404s on
every request, the "killed" node is still serving because the wrapper died and the JVM did
not, the 403 was counted as a missing key. Hence the gates, the baseline, and three-valued
verdicts with INCONCLUSIVE as a real answer.

**Be honest about the gap.** `configuration-diff.txt` lists every deviation between the lab
and the customer's environment, including the ones that weaken the verdict.

## Safety

Destructive operations are confined to the reproduction environment. Targets must be inside
this workspace's `output/<case>-<timestamp>/`, which is asserted before any `rm -rf`. Only
PIDs this run recorded are signalled, and their command line is re-checked immediately
before the signal, because PIDs get reused — `pkill -f java` has no safe form. Nothing here
targets production infrastructure. Full rules in `reference/safety-rules.md`.

## Layout

```
workspaces/<product>/    run.sh · workspace.env · README.md · input/ · output/
lib/                     common.sh case.sh eap.sh datagrid.sh jvm.sh report.sh flow.sh
templates/case.txt       the case template each workspace's input/case.txt starts from
templates/apps/          session-cluster · simple-web · cache-harness · jvm-workload
reference/               version-matrix.md · safety-rules.md · lab-targets.txt
```

`lib/` holds the drivers; they are version-agnostic and read every product-specific fact
from the workspace's `workspace.env`. Adding a fifth product means adding a directory with
a `workspace.env` and a `run.sh`, not editing the drivers.

## Requirements

- bash 4.4+, curl, java, maven (for the EAP test applications)
- **the product binaries.** They are not in this repository and cannot be — EAP and Data
  Grid are downloaded from the Red Hat Customer Portal under your own subscription. You
  unpack them yourself; see below.

## Setup: where to put the binaries and the JDKs

Nothing is installed by this repository. Each run looks for a product installation and a
JDK already on the host, and stops with `BLOCKED` naming what it could not find rather than
substituting something else.

### The product installation

Download the **zip** distribution from [access.redhat.com/downloads](https://access.redhat.com/downloads)
and unpack it. Either put it where the workspace already looks, or point at it explicitly —
the environment variable always wins over the search.

| workspace | download | searched, in order | override |
|---|---|---|---|
| `eap7` | Red Hat JBoss EAP 7.x | `~/Documents/EAP_lab/jboss-eap-7*` · `/opt/jboss-eap-7*` · `~/jboss-eap-7*` · `/opt/rh/eap7` | `EAP_HOME=` |
| `eap8` | Red Hat JBoss EAP 8.x | `~/Documents/EAP_lab/jboss-eap-8*` · `/opt/jboss-eap-8*` · `~/jboss-eap-8*` · `/opt/rh/eap8` | `EAP_HOME=` |
| `datagrid` | Red Hat Data Grid 8.x **Server** | `~/Documents/Datagrid/redhat-datagrid-*-server` · `~/Documents/EAP_lab/redhat-datagrid-*-server` · `/opt/redhat-datagrid-*-server` · `~/infinispan-server-*` | `RHDG_HOME=` |
| `jvm` | nothing — the JDK *is* the product | — | — |

```bash
mkdir -p ~/Documents/EAP_lab && cd ~/Documents/EAP_lab
unzip ~/Downloads/jboss-eap-7.4.0.zip        # -> jboss-eap-7.4.0/jboss-eap-7.4/
unzip ~/Downloads/jboss-eap-8.1.0.zip

mkdir -p ~/Documents/Datagrid && cd ~/Documents/Datagrid
unzip ~/Downloads/redhat-datagrid-8.5.2-server.zip
```

Or leave the binaries wherever they are:

```bash
EAP_HOME=/srv/labs/jboss-eap-7.4 ./run.sh
RHDG_HOME=/srv/labs/redhat-datagrid-8.5.2-server ./run.sh
```

`EAP_HOME` is the directory holding `bin/standalone.sh`. One level of nesting is searched
automatically, because the EAP archives unpack as `jboss-eap-7.4.0/jboss-eap-7.4/`.
`RHDG_HOME` is the directory holding `bin/server.sh`.

The search paths are not hardcoded in the drivers — they are `WS_INSTALL_GLOB` in each
`workspaces/<product>/workspace.env`. Edit that line if your lab lives somewhere else and
you would rather not export a variable on every run.

**Keep more than one version unpacked if you support more than one.** Discovery collects
every candidate and picks the install whose **own version banner** agrees with the case, not
the first one the glob returns; the newest is only the fallback. This is what lets an 8.2
case and an 8.1 case run on the same machine and each get the right server. A wrong-major
install in a workspace is refused outright: an EAP 8 tree under `eap7/` stops the run.

### The JDK

`java` on `PATH` is not enough — the run needs a JDK of the **major version the case names**,
and for a JVM case it will not substitute another one. Searched, in order:

1. `$JAVA_HOME` — used only if its major matches what the case asks for
2. `/usr/lib/jvm/*/` — where RHEL and Fedora put `java-17-openjdk` and friends
3. `~/jdks/*/` — unpack tarball JDKs here
4. `/opt/jdk*/` and `/opt/java/*/`

```bash
sudo dnf install java-11-openjdk-devel java-17-openjdk-devel java-21-openjdk-devel
```

Defaults if the case names no JDK: EAP 7 → 11, EAP 8 → **17** (EAP 8 will not boot on 11 —
its own modules are compiled to class file 61), Data Grid → 17, JVM → 17. `./run.sh` prints
every JDK it found when it cannot satisfy the case. `--allow-jdk-substitute` lets a run
proceed on a different JDK and puts that substitution at the top of the deviation list.

### If it cannot find them

There is no separate discovery check: the run resolves the install and the JDK as its first
steps and prints both, so a misconfigured host fails in seconds rather than halfway through.
Missing pieces end the run as `BLOCKED` (exit 4) with the paths it searched and the exact
variable to set — a blocked run is a broken lab, never a statement about the customer's
issue. `./run.sh --clean` stops anything a previous run left up and frees the workspace's
ports; it is cleanup, not a dry run.

## `.claude/`

The `.claude/` directory is left over from an earlier agent-driven version of this tool. It
is not used by `run.sh` and nothing in `lib/` reads it. It is safe to delete.
