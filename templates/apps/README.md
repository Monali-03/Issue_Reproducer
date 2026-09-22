# Test application blueprints

The agent picks one of these per case and builds it automatically. The customer almost
never ships their WAR, so the reproducer bundles its own — that is what keeps the
"requirements" list short.

| Blueprint | Form | Use when |
|---|---|---|
| `session-cluster` | WAR, **`<distributable/>`** | session replication, failover, sticky load balancing, clustering |
| `simple-web` | WAR, not distributable | deployment failures, TLS, datasources, classloading, JVM behavior |
| `cache-harness` | shell + REST driver | Red Hat Data Grid / Infinispan **server** — cache create, write, read-back, cross-site |

## Selection

Decided by `.claude/skills/build-test-app`. Short version: clustering signals in the case
(session loss, failover, mod_cluster/mod_proxy, `<distributable/>`, JGroups) →
`session-cluster`. A Data Grid *server* case → `cache-harness`. Anything else →
`simple-web`.

An EAP case that uses the embedded `infinispan` subsystem is still an EAP case: use
`session-cluster` and reach the cache through the session, rather than the Data Grid
harness, which drives a standalone server over REST.

## Namespaces

`prepare-app.sh <blueprint> <dest>` substitutes the servlet namespace from `TARGET_MAJOR`:

| Major | Java imports | web.xml namespace |
|---|---|---|
| 7.x | `javax.servlet` | `http://xmlns.jcp.org/xml/ns/javaee` 4.0 |
| 8.x | `jakarta.servlet` | `https://jakarta.ee/xml/ns/jakartaee` 6.0 |

It fails loudly on any unsubstituted `__TOKEN__` rather than shipping a broken WAR.

This matters more than it looks: a WAR built against `javax.servlet` **deploys
successfully** on EAP 8 and reports healthy in the management console, while every servlet
returns 404 because the annotations are never scanned. Which is why `start.sh` gate 4
calls the endpoint instead of reading deployment status.

## What each probe gives you

**`session-cluster`** — `GET /session` returns JSON with `node`, `sessionId`, `counter`,
`newSession`, `existedBeforeRequest`, `creationTime`. Every response carries
`X-Repro-Node`. `newSession` plus `existedBeforeRequest` is what separates "the session
replicated" from "the failover node quietly issued a new one" — the exact line between NOT
REPRODUCED and REPRODUCED. Also `?set=k:v`, `?get=k`, `?invalidate`, `?size=N` for
replication payload sizing.

**`simple-web`** — `GET /info` returns node, host, scheme, `secure`, protocol, JVM version
and vendor, heap, processors, plus `?prop=` / `?env=` lookups. `GET /health` is a plain
200 for readiness polling.

**`cache-harness`** — `./cache-harness.sh all` creates the cache, writes `ENTRY_COUNT`
entries, prints cluster membership as each node sees it, then reads **every entry from
every node** and reports per-node hits/misses/errors.

Three behaviors it handles that otherwise produce false reproductions:

- Digest auth, because the default properties realm stores hashed credentials and rejects
  Basic. Auth is proven against a real cache call before anything is measured — the health
  endpoint answers anonymously, so it would report healthy against a server that 403s
  everything.
- Caches created over REST are permanent, so it deletes before creating; otherwise a rerun
  inherits the previous run's entries.
- Non-200/404 responses are counted as **errors**, never as misses. Folding a 403 into the
  miss column is precisely how a tool reports a replication bug that is not there.

## Customising

These are starting points. When the case needs something specific — a particular session
attribute type, a datasource, a JAX-RS resource, a custom cache encoding — extend the
blueprint in the generated package under `output/<case-id>/app/`, not here, and record the
change in `configuration-diff.txt`.
