---
name: build-test-app
description: Choose, build and deploy the test application for a reproduction - a distributable session WAR for clustering/failover cases, a plain WAR for non-clustering cases, or the REST cache harness for Data Grid server cases - then verify the endpoint actually answers. Use during generation when the case needs an application to exercise, which is almost always.
---

# Build the test application

The customer almost never ships their WAR. Bundling one is what keeps the reproduction's
"requirements" list down to genuinely irreducible items, so **build one by default** — ask
only if the case clearly needs a specific application the blueprints cannot stand in for.

## Selection

Read the case, then pick:

| Signals in the case | Blueprint |
|---|---|
| session loss, failover, sticky sessions, mod_cluster / mod_proxy_balancer, `<distributable/>`, JGroups, `web-session` cache, "restarting node N loses sessions" | `session-cluster` |
| Data Grid / Infinispan **server**, Hot Rod, REST cache API, cross-site / RELAY2, `ISPN*` codes from a standalone server | `cache-harness` |
| deployment failure, TLS/SSL handshake, datasource, classloading, JVM/GC/heap, Elytron auth, anything with no clustering dimension | `simple-web` |

Two cases that look ambiguous and are not:

- **EAP with the embedded `infinispan` subsystem** is an EAP case, not a Data Grid case.
  Use `session-cluster` and reach the cache through the session. `cache-harness` drives a
  standalone Data Grid server over REST and does not apply.
- **Data Grid accessed *from* an EAP app** needs both: `session-cluster` (or `simple-web`)
  on EAP, plus `cache-harness` to prove the Data Grid side independently. When the
  end-to-end path fails, that second probe is what tells you which side broke.

If the customer supplied their own WAR/EAR in `input/attachments/`, prefer it — it is
higher fidelity than anything you can write. Deploy it, and fall back to a blueprint only
if it will not build or needs infrastructure you do not have. Record which you used in
`configuration-diff.txt`.

## Build

```bash
export TARGET_MAJOR TARGET_JDK APP_NAME      # from nodes.env
templates/apps/prepare-app.sh <blueprint> "$PKG/app"
```

`prepare-app.sh` substitutes the namespace from `TARGET_MAJOR` (`javax.*` for 7.x,
`jakarta.*` for 8.x), builds with Maven, and fails loudly on any unsubstituted token.

Getting the namespace wrong does not fail the build or the deployment — the WAR deploys
cleanly, the management console reports it healthy, and every servlet returns 404 because
the annotations are never scanned. This is why the next step is mandatory.

## Deploy and prove it answers

Copy the WAR into **each node's own** `deployments/` directory — the per-node base dir,
never the shared installation.

Then call the endpoint. Every node, HTTP 200, expected body:

```bash
curl -fsS "http://$BIND_ADDR:$port/$APP_NAME/session" | tee /dev/stderr | grep -q '"node"'
```

**Deployment status is not proof.** `start.sh` gate 4 exists for exactly this. A 404 here
means the namespace, the context path, or the annotation scanning — not the customer's bug.

For `cache-harness` there is no WAR. Prove the equivalent:

```bash
templates/apps/cache-harness/cache-harness.sh create
templates/apps/cache-harness/cache-harness.sh put 100
templates/apps/cache-harness/cache-harness.sh members     # every node must see the others
templates/apps/cache-harness/cache-harness.sh verify      # every entry from every node
```

That sequence *is* the baseline for a Data Grid case: entries written, cluster formed,
every entry readable everywhere. Only once it passes may a node be killed.

## Configuring the application into the server

Keep server-side wiring in a CLI script under `config/eap/<node>.cli` rather than hand-
edited XML — it survives version drift and self-documents in the package. What needs wiring
depends on the case: a distributed web-session cache for clustering, a datasource, an
Elytron domain, a TLS `key-store` and `ssl-context`.

Match the customer's settings where they gave them. Where they did not, use the product
default and record it as INFERRED — a cache mode or owner count you invented can produce or
mask the symptom on its own.

## Cache entries — write them, then verify from everywhere

For any case where data is supposed to be shared across nodes, the harness must
**automatically** populate and then check, with no manual step:

1. Create the cache with a known configuration (`cache-config.json`, or the customer's).
2. Write a known set of entries — `key-1..key-N` with predictable values, so a wrong value
   is as detectable as a missing one.
3. Read **every** entry from **every** node before touching anything. That is the baseline.
4. Only then inject the failure, and re-read.

Count three outcomes, never two: hit, miss, and **error**. A 403, a timeout or a connection
refusal is an error, not a miss. Folding errors into the miss column is the single most
common way a harness reports a replication bug that does not exist.

## Sizing

Default to a small entry count and a small session — enough to be decisive, fast to run.
Scale up only when the case points at size or load: a large session payload for replication
timeouts (`?size=N`), thousands of entries for rebalance behavior, concurrent clients for
lock contention. Say in the plan why you chose the number; an arbitrary load that happens
to trigger something is not a reproduction of the customer's scenario.
