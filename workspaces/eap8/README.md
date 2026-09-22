# eap8 — JBoss EAP 8.x reproducer

Reproduces customer issues against a **JBoss EAP 8.x** installation. This workspace reads
only its own `input/` and writes only its own `output/`. It will refuse an EAP 7, Data Grid
or JDK case outright rather than run it against the wrong product.

## 1. Drop the case in

```
workspaces/eap8/input/
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
Version: 8.1.0
```

Then describe the symptom in prose. The scenario driver is chosen from the wording —
"sessions lost", "logged out", "failover" select the session-failover driver; "deadlock",
"OutOfMemory", "certificate", "connection pool", "404" each select their own.

## 2. Run it

```bash
cd workspaces/eap8
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

It does need an EAP 8.x installation and a matching JDK already on the host — neither is
shipped here. Unpack the zip under `~/Documents/EAP_lab/`, `/opt/`, or your home directory,
or point at it with `EAP_HOME=/path/to/jboss-eap-8.1 ./run.sh`. The JDK must be **17 or
21**: EAP 8 dies before reading any configuration on JDK 11, because its own modules are
compiled to class file 61. `dnf install java-17-openjdk-devel`. The exact search paths and
the version-matching rules are in the repository README under **Setup**. If either is
missing the run ends `BLOCKED` with the paths it tried.

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

http `9080 9180 9280` · management `10990 11090 11190` · JGroups `8600 8700 8800`.

Disjoint from eap7 and datagrid, so all three can run at the same time. Each workspace also
takes its own `.run.lock`, which stops two runs of *this* workspace from colliding.

## What it will not do

- **It will not run another product's case.** An `eap7` or Data Grid case in this folder is
  a hard error naming the folder it belongs in.
- **It will not guess.** Anything the case does not state is marked `INFERRED` with its
  derivation, or `NOT PROVIDED`. No bug IDs, KB numbers or "fixed in" claims are ever
  emitted — those come from the Customer Portal, not from a script.
- **It will not report a reproduction it cannot show.** Five startup gates (ports → clean
  boot → cluster formed in every node's view → endpoint returns 200 → routing) and a
  passing baseline run *before* any failure is injected. If a gate fails the run exits
  BLOCKED (status 4) instead of producing a verdict, because a lab that is already broken
  reproduces every symptom.

## Notes specific to EAP 8

- **EAP 8.x is Jakarta EE 10**: the test application is built against `jakarta.*`. This is
  the most expensive trap in the product family — a WAR built against `javax.servlet`
  deploys *successfully* on EAP 8 and reports healthy in the console while every servlet
  returns 404, because the annotations are never scanned. Gate 4 therefore calls the
  endpoint rather than trusting deployment status.
- Multicast discovery does not work between processes on one host, so the run overlays
  TCPPING onto the `tcp` stack. On EAP 8.1 `standalone-ha.xml` hardcodes
  `<channel name="ee" stack="udp"/>` with no expression around the stack name, so
  `-Djboss.default.jgroups.stack` is silently ignored; the run rewrites the channel's stack
  explicitly and verifies the result in the written XML before starting anything.
- EAP 8.1 leaves the jgroups channel's runtime attributes undefined over the management
  API even with statistics enabled, so the cluster-formation gate falls back to the
  Infinispan membership lines in `server.log`. `evidence/before/cluster-views.txt` records
  which source each node's answer came from.
- The default JDK is 17. If the case names a JDK that is not installed, the run says so and
  records the substitution rather than pretending.
