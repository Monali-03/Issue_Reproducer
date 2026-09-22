# Case library — 16 customer-facing issues, 4 per product

These are **synthetic customer reports written for this harness**, not transcripts of real
Red Hat tickets. Every version, error string, log line and config value below is authored
to be *plausible and self-consistent*, so they exercise the drivers end to end — but per
rule 2 in `../CLAUDE.md`, nothing here is evidence of anything. A verdict comes from a run,
not from this file.

Each directory is a drop-in input set:

```
cases/<product>/<ID>-<slug>/
  case.txt        the customer report, in templates/case.txt format
  configs/        the configuration file(s) the issue turns on
```

## How to run one

The workspaces read `workspaces/<product>/input/`, so copy a case in:

```bash
cd <the repository root>
cp cases/eap8/E8-02-migrated-war-404/case.txt          workspaces/eap8/input/case.txt
cp cases/eap8/E8-02-migrated-war-404/configs/*         workspaces/eap8/input/configs/
./workspaces/eap8/run.sh
```

`workspaces/<product>/input/case.txt` already holds a case — back it up first if you want
to keep it. Four of the sixteen (E7-01, E8-01, DG-01, JV-01) are expanded versions of the
cases already sitting in those directories.

---

## EAP 7 — `cases/eap7/`

| ID | Issue | Product version | JDK | RHEL | Configuration file | Scenario |
|---|---|---|---|---|---|---|
| E7-01 | Session lost on failover — node2 issues a new JSESSIONID after node1 is killed | JBoss EAP 7.4.0 GA | OpenJDK 11.0.22 | RHEL 8.9 | `standalone-ha.xml` (web cache-container) + app `web.xml` | `session-failover`, stack `udp` |
| E7-02 | Datasource pool exhausted under load — `IJ000453` / `IJ000655`, never recovers | JBoss EAP 7.4.0 GA | OpenJDK 11.0.22 | RHEL 8.10 | `standalone-full.xml` (datasources subsystem) | `datasource` |
| E7-03 | TLS handshake fails for one partner — `no cipher suites in common` | JBoss EAP 7.4.0 GA | OpenJDK 8u412 | RHEL 7.9 | `standalone.xml` (elytron tls + https-listener) | `tls` |
| E7-04 | Node stops answering HTTP — Java-level deadlock between an EJB timer and the web tier | JBoss EAP 7.4.0 GA | OpenJDK 11.0.22 | RHEL 8.9 | `standalone-ha.xml` (io worker + ejb3 subsystem) | `deadlock` |

## EAP 8 — `cases/eap8/`

| ID | Issue | Product version | JDK | RHEL | Configuration file | Scenario |
|---|---|---|---|---|---|---|
| E8-01 | 3 nodes never form a cluster on the udp stack — each is a cluster of one | JBoss EAP 8.1.0 GA | OpenJDK 21.0.11 | RHEL 9.4 | `standalone-ha.xml` (jgroups subsystem) | `cluster-formation`, stack `udp` |
| E8-02 | WAR migrated from 7.4 deploys successfully, then 404s on every URL | JBoss EAP 8.1.0 GA | OpenJDK 21.0.11 | RHEL 9.4 | app `web.xml` (javax namespace) + stock `standalone.xml` | `deployment` |
| E8-03 | Heap never returns after redeploy — OOM after ~40 hot redeploys | JBoss EAP 8.1.0 GA | OpenJDK 17.0.11 | RHEL 9.3 | `bin/standalone.conf` (JAVA_OPTS) | `memory` |
| E8-04 | HTTPS handshake_failure after migration — PKCS12 keystore declared as JKS | JBoss EAP 8.1.0 GA | OpenJDK 21.0.11 | RHEL 9.4 | `standalone.xml` (elytron tls + https-listener) | `tls` |

## Data Grid — `cases/datagrid/`

| ID | Issue | Product version | JDK | RHEL | Configuration file | Scenario |
|---|---|---|---|---|---|---|
| DG-01 | Half the entries vanish when one of two nodes is killed | RHDG 8.5.2 server | OpenJDK 21.0.11 | RHEL 9.4 | cache definition `reprocache.json` (`owners: 1`) | `cache` |
| DG-02 | Three servers each form a cluster of one after multicast was disabled | RHDG 8.5.2 server | OpenJDK 21.0.11 | RHEL 9.4 | `server/conf/infinispan.xml` (jgroups stack-file) | `cluster-formation`, stack `udp` |
| DG-03 | Cross-site backup never replicates; remote site reported offline | RHDG 8.6.1 server | OpenJDK 21.0.11 | RHEL 9.5 | `server/conf/infinispan.xml` (RELAY2 + backups) | `xsite` |
| DG-04 | REST calls 401/403 with the right password while `/health/status` says HEALTHY | RHDG 8.5.2 server | OpenJDK 21.0.11 | RHEL 9.4 | `server/conf/infinispan.xml` (security realm + rest-connector) + `users.properties` | `generic` |

## OpenJDK / JVM — `cases/jvm/`

| ID | Issue | Product version | JDK | RHEL | Configuration file | Scenario |
|---|---|---|---|---|---|---|
| JV-01 | `OutOfMemoryError: Java heap space` after 3–6 h of steady load | Red Hat build of OpenJDK 17.0.11 | OpenJDK 17.0.11 | RHEL 9.3 | `configs/jvm-args.txt` (2 g heap, G1) | `memory` |
| JV-02 | G1 pauses exceed 3 s against a 200 ms target; all cores to 100% | Red Hat build of OpenJDK 21.0.11 | OpenJDK 21.0.11 | RHEL 9.4 | `configs/jvm-args.txt` (8 g heap, G1, gc+safepoint logging) | `cpu-gc` |
| JV-03 | Batch service stops making progress — jstack reports a Java-level deadlock | Red Hat build of OpenJDK 11.0.22 | OpenJDK 11.0.22 | RHEL 8.9 | `configs/jvm-args.txt` (1 g heap, default collector) | `deadlock` |
| JV-04 | `OutOfMemoryError: Metaspace` after ~90 rule reloads; heap stays healthy | Red Hat build of OpenJDK 25.0.3 | OpenJDK 25.0.3 | RHEL 9.5 | `configs/jvm-args.txt` (`MaxMetaspaceSize=256m`) | `memory` |

---

## What this lab can and cannot honour

Measured on this host, not recalled:

- **OS: Fedora 43 x86_64.** No RHEL is installed. Every "RHEL" column above is the
  *customer's* stated OS and is a standing deviation on every run — glibc, kernel and
  NSS/crypto policy all differ, which matters most for the TLS cases (E7-03, E8-04).
- **Products installed:** EAP 7.4.0, EAP 8.1.0, RHDG 8.5.2, RHDG 8.6.1 — by directory name.
  The EAP 7 tree's banner actually reads `Version 7.4.23.GA`: it is a patched install, not
  GA. The four E7 cases name 7.4.0, so each now runs with a recorded version deviation
  (customer=7.4.0, reproducer=7.4.23). That is the check working, not a fault — change the
  `Version:` line to 7.4.23 if you want the deviation gone.
  RHDG 8.6.1 lives under `Documents/EAP_lab/`, and the datagrid glob finds 8.5.2 first, so
  DG-03 needs `RHDG_HOME=...8.6.1-server`. The EAP drivers no longer have this problem:
  `eap_discover` picks the install whose banner matches the case (see `lib/eap.sh`).
- **JDKs installed:** Temurin 11.0.32.1+1, Red Hat build of OpenJDK 21.0.11, Red Hat build
  of OpenJDK 25.0.3.

That last point blocks three cases as written. Per rule 5 the drivers stop at BLOCKED
(exit 4) rather than substituting:

| Case | Needs | Status |
|---|---|---|
| E7-03 | JDK 8 | **BLOCKED** — no JDK 8 on this host |
| E8-03 | JDK 17 | **BLOCKED** — no JDK 17 on this host |
| JV-01 | JDK 17 | **BLOCKED** — no JDK 17; `jvm.sh` refuses to substitute, a JVM symptom is version-specific |

Install those JDKs, or run with `--allow-jdk-substitute` and read the deviation line before
the verdict. The remaining thirteen run on installed bits.

Two smaller gaps worth knowing before you trust a verdict:

- **JDK 11 is Temurin here, not the Red Hat build** (and 11.0.32.1 ≠ the 11.0.22 the E7 and
  JV-03 cases name). Fine for EAP 7, where the driver matches on major; note it for JV-03.
- **`xsite` has no driver.** `detect_scenario` routes DG-03 to `xsite`, but `flow.sh`
  handles it on the same single-cluster kill-a-node path as `cache` — there is no second
  site and no RELAY2 link. DG-03 is a real case shape, but the current harness cannot
  reproduce it faithfully; expect a verdict about something else.

## Which cases get a real measurement

Six scenarios have hand-written paths. The rest now go through the generic engine
(`reference/measurement-plans.md`), which builds probes and a criterion from what the case
states instead of grepping for its error text:

| Case | Path | What decides it |
|---|---|---|
| E7-01, E8-01, DG-01, DG-02, JV-02, JV-03 | hand-written | unchanged |
| E7-02 | engine | IJ000453 / IJ000655 / `javax.resource.ResourceException` appearing under 20×50 concurrent requests |
| E7-03, E8-04 | engine | `javax.net.ssl.SSLHandshakeException` (E8-04 also `WFLYELY00023`) with no fault injected — the keystore *is* the fault |
| E7-04 | engine | WFLYSRV0295 appearing under load |
| E8-02 | engine | the endpoint returning 404 after 10 redeploy cycles |
| E8-03 | engine | OOM / WFLYSRV0022 increasing across 10 redeploys |
| DG-04 | engine | the cache endpoint returning 401 plus ISPN000287 |
| JV-01, JV-04 | engine | `java.lang.OutOfMemoryError` in this run's own logs |

Preview any of them without starting a server:

```bash
./tools/show-plan.sh cases/eap7/E7-02-datasource-pool-exhausted/case.txt 2
```

**A derived plan cannot produce a confident negative.** When the run uses the shipped
configuration *and* the harness's own test application, neither the customer's code nor
their configuration was ever under test, so a missing symptom says nothing about the
product: the engine downgrades NOT REPRODUCED to INCONCLUSIVE and records why. Measured on
E7-04 — the case is a deadlock between an EJB timer and the web tier, and the lab's WAR has
neither, so 1000 requests landed, all 2xx, and the run correctly refused to call it a
negative. To get a real verdict on these, supply `input/configs/<their standalone*.xml>`,
`input/attachments/<their .war>`, or a stated `input/plan.env`.
