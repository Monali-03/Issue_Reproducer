# eap7 — JBoss EAP 7.x reproducer

Reproduces customer issues against a **JBoss EAP 7.x** installation. This workspace reads
only its own `input/` and writes only its own `output/`. It will refuse an EAP 8, Data Grid
or JDK case outright rather than run it against the wrong product.

## 1. Drop the case in

```
workspaces/eap7/input/
├── case.txt            ← the customer's scenario (REQUIRED)
├── configs/            ← standalone*.xml, *.properties, anything they sent
├── logs/               ← server.log, boot.log, console output
├── dumps/              ← thread dumps, heap dumps
└── attachments/        ← their WAR/EAR, if they gave you one
```

`input/case.txt` is a filled-in copy of `templates/case.txt`. Two lines decide everything
and are not optional:

```
Product: Red Hat JBoss EAP
Version: 7.4.0
```

Then describe the symptom in prose. The scenario driver is chosen from the wording —
"sessions lost", "logged out", "failover" select the session-failover driver; "deadlock",
"OutOfMemory", "certificate", "connection pool", "404" each select their own.

## 2. Run it

```bash
cd workspaces/eap7
./run.sh
```

| flag | effect |
|---|---|
| `--nodes N` | override the node count detected from the case |
| `--scenario NAME` | override scenario detection |
| `--keep-running` | leave the servers up afterwards so you can poke at them |
| `--clean` | kill anything this workspace left running, then exit |

From there the reproducer discovers the EAP installation, picks the JDK, plans ports, seeds
one isolated server tree per node, **builds the test application itself**, deploys it,
starts the cluster and drives the scenario.

### Prerequisites

An EAP **7.x** installation and a matching JDK have to be on the host already — neither is
shipped here. Unpack the zip from the Customer Portal anywhere you like, install a JDK
(`sudo dnf install java-11-openjdk-devel`), and name both:

```bash
export EAP_HOME=/opt/labs/jboss-eap-7.4        # the directory holding bin/standalone.sh
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk
./run.sh
```

`EAP_HOME` must be an EAP **7** tree here; an 8.x tree is refused rather than run. Leave it
unset and the workspace searches `~/Documents/EAP_lab/jboss-eap-7*`, `/opt/jboss-eap-7*`,
`~/jboss-eap-7*` and `/opt/rh/eap7` instead. `JAVA_HOME` is used only when its major matches
the JDK the case names; the default is 11. If either is missing the run ends `BLOCKED` with
the paths it tried. Full details in the repository README.

## 3. What comes out

`output/<case>-<timestamp>/`, with `output/latest` pointing at the most recent run:

| file | what it is |
|---|---|
| `VERDICT.txt` | REPRODUCED / NOT REPRODUCED / INCONCLUSIVE / BLOCKED, and why |
| `SOLUTION.md` | ranked candidate causes, each with a check command and a fix |
| `README.md` | the run written up, in the order someone else would re-run it |
| `reproduction.log` | everything the run printed |
| `commands.log` | every external command, with its exit status |
| `configuration-diff.txt` | every way the lab differs from the customer's environment |
| `logs/` | each node's `server.log`, `gc.log`, console output |
| `config/` | the exact configuration each node booted with |
| `evidence/before/ during/ after/` | cluster views, session JSON, thread dumps |
| `nodes/` | the whole seeded server tree per node (not archived) |
| `../<case>-<timestamp>.tar.gz` | the package minus `nodes/` and heap dumps — this is what you attach |

## Ports it uses

http `8080 8180 8280` · management `9990 10090 10190` · JGroups `7600 7700 7800`.

Disjoint from eap8 and datagrid, so all three can run at the same time. Each workspace also
takes its own `.run.lock`, which stops two runs of *this* workspace from colliding.

## What it will not do

- **It will not run another product's case.** An `eap8` or Data Grid case in this folder is
  a hard error naming the folder it belongs in.
- **It will not guess.** Anything the case does not state is marked `INFERRED` with its
  derivation, or `NOT PROVIDED`. No bug IDs, KB numbers or "fixed in" claims are ever
  emitted — those come from the Customer Portal, not from a script.
- **It will not report a reproduction it cannot show.** Five startup gates (ports → clean
  boot → cluster formed in every node's view → endpoint returns 200 → routing) and a
  passing baseline run *before* any failure is injected. If a gate fails the run exits
  BLOCKED (status 4) instead of producing a verdict, because a lab that is already broken
  reproduces every symptom.

## Notes specific to EAP 7

- EAP 7.x is Jakarta EE 8: the test application is built against `javax.*`.
- Multicast discovery does not work between processes on one host, so the run overlays
  TCPPING with explicit `initial_hosts` onto the `tcp` stack and points the `ee` channel at
  it. That substitution is recorded in `configuration-diff.txt`.
- The default JDK is 11. If the case names a JDK that is not installed, the run says so and
  records the substitution rather than pretending.
