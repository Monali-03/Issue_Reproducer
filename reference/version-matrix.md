# Version matrix — how to resolve product facts

Spec §3 requires a version-aware knowledge base. Spec §21 forbids guessing. Those combine
into one rule:

> **Resolve version facts from the artifact in front of you, or from Red Hat documentation
> you actually fetched. Never from recall.**

Product versions change supported JDKs, schema namespaces, subsystem names, default
protocol stacks and API namespaces between releases — sometimes between micro releases.
A remembered mapping that was right a year ago produces a reproduction that fails at boot
for reasons unrelated to the customer's issue, and burns an hour before anyone notices.

---

## Resolution order for every fact

### 1. The installation itself — most authoritative

| Fact | Where to read it |
|---|---|
| Product version | `$PRODUCT_HOME/version.txt`; the boot banner in `log/server.log`; `$EAP_HOME/bin/product.conf` + the matching `modules/system/layers/base/org/jboss/as/product/*/dir/META-INF/MANIFEST.MF` |
| Patch / CP level | The version string after patching — GA and patched installs differ only here |
| Schema namespace | The root element's `xmlns` in the install's **own** stock `standalone.xml` / `infinispan.xml`. Copy that string; do not type one from memory |
| Available profiles | `ls $EAP_HOME/standalone/configuration/*.xml` |
| Default JGroups stacks | The `jgroups` subsystem in the install's stock HA profile |
| Subsystem availability | `jboss-cli.sh -c --command='/:read-children-names(child-type=subsystem)'` on a running server |

The **boot banner is the ground truth** for what version is actually running. It outranks
the directory name, the case text, and what the customer told support.

### 2. The customer's artifacts

Their `server.log` banner tells you the version they really ran — often not the version
they reported. When the two disagree, that discrepancy goes in the report; it has decided
more than one case.

### 3. Red Hat documentation — fetch it, don't recall it

For supported JDKs, supported operating systems, and lifecycle dates, search and read:

```
WebSearch: "<product> <version> supported configurations site:access.redhat.com"
WebFetch:  the supported-configurations article for that product
```

Red Hat publishes a supported-configurations article per product, and a lifecycle page per
product family. Those are the citable sources. If you cannot reach them, mark the fact
**UNVERIFIED** and proceed with what the installation tells you — never substitute a
remembered value for a fetched one.

---

## Facts that are stable enough to rely on structurally

These are architectural, not version-lookup, and they hold across the release:

**Jakarta namespace boundary.** EAP 7.x is Jakarta EE 8 and uses `javax.*`. EAP 8.x is
Jakarta EE 10 and uses `jakarta.*`. This is the single most expensive trap in the product
family: a WAR built against `javax.servlet` **deploys successfully** on an EAP 8 server and
reports healthy in the management console, while every servlet returns 404, because the
annotations are never scanned. Consequence for this agent: **always verify a deployment by
calling its endpoint**, never by reading deployment status.

**Config schemas are not portable across majors or most minors.** Never copy a
`standalone-ha.xml`, `infinispan.xml` or JGroups stack from one release into another. Start
from the target install's own stock file and layer changes onto it — preferably through
`jboss-cli.sh --file=` or a documented overlay, which survives version drift better than
hand-edited XML and self-documents in the package.

**Newer JDKs reject older configurations.** Running an older EAP on a JDK beyond its
supported range does not merely warn — legacy subsystems can be rejected outright and the
server dies during boot before anything deploys. Treat a boot failure on an unsupported JDK
as an environment fault, not as the customer's issue, and check the JDK before debugging
anything else.

**Data Grid tracks Infinispan.** Each Data Grid release corresponds to an upstream
Infinispan release, and the configuration schema follows the Infinispan major. Read the
namespace out of the install's own `infinispan.xml`; do not assume it matches the Data Grid
version number.

**Discovery defaults are environment-dependent.** A product's stock TCP stack may use a
multicast discovery protocol, which finds nothing on a single lab host — loopback typically
carries no MULTICAST flag and the firewall drops it on the NIC. Each node then forms a
cluster of one, and every clustering symptom downstream is a harness artifact. Check
`ip -br link` and test before relying on a multicast-based stack; use a static/unicast
discovery protocol in the lab and record the substitution in the config diff.

---

## Per-case checklist

Before generating anything, fill this in and put it in `reproduction-plan.md`:

```
Product:                 <name>
Version claimed (case):  <x.y.z>
Version verified:        <from banner/version.txt>   [MATCH | MISMATCH | UNVERIFIED]
Patch/CP level:          <x.y.z.CPnn or GA>
JDK required:            <range>   source: <fetched URL | install docs | UNVERIFIED>
JDK to be used:          <path + version>   [SUPPORTED | UNSUPPORTED | UNVERIFIED]
Config schema namespace: <copied verbatim from the install's stock config>
API namespace:           javax.* | jakarta.*
Discovery protocol:      <stock> → <lab substitution, if any>
Version-specific issue?  yes → differential candidates <list> | no | UNKNOWN
```

`UNVERIFIED` is an acceptable entry. A confidently wrong value is not.

---

## Differential testing

When the case points at a version boundary, get the neighbouring builds and test them —
one variable at a time, product version **or** JDK, never both. Apply cumulative patches
onto a GA install rather than hunting for a standalone build of each micro version; CPs are
cumulative, so any single CP reaches its level in one step.

Rules:

- Match the customer's exact version when it is known. A verdict about 7.4.23 from a run on
  7.4.0 is not a verdict about 7.4.23, in either direction.
- When the version is unknown, test the latest available. Reproducing on latest means a
  live bug. Not reproducing on latest, having reproduced on an older build, means it is
  likely already fixed — which makes "upgrade" the recommendation, stated as an observation
  about your test rather than as a confirmed fix.
- Report the boundary as observed behavior. Do not attach a bug ID, a commit or a release
  note unless you fetched and read it.
