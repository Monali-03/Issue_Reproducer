---
name: collect-evidence
description: Capture before/during/after evidence for a reproduction - server and boot logs, GC logs, thread dumps, JVM flags and system properties, cluster membership, cache and JGroups state, HTTP transcripts, and OpenShift pod/event/resource state. Use as stage 8 of a reproduction, or standalone when a run needs to be evidenced after the fact.
---

# Collect — evidence

Three phases, three directories. A capture taken only at the end cannot show that anything
changed, which is usually the entire claim.

```
evidence/
├── before/    environment, process state, cluster view, config, network, baseline
├── during/    the exact command + timestamp, state at injection, live logs
└── after/     final state, logs, errors, cluster view, application state
```

Timestamp everything, ISO-8601 with timezone. Use the same clock source throughout so the
three phases are comparable.

## Java / JBoss EAP

Per node, per phase:

```bash
# identity and configuration
jps -lv
jcmd <pid> VM.command_line
jcmd <pid> VM.flags
jcmd <pid> VM.system_properties

# state
jcmd <pid> Thread.print
jcmd <pid> GC.heap_info
```

Logs to copy: `standalone-nodeN/log/server.log`, `boot.log`, any GC log, plus the LB's
access and error logs. Copy them — do not move them, and do not truncate the originals
mid-run.

For a hang or a deadlock, take **three thread dumps about ten seconds apart**. One dump
shows threads at an instant; three show whether they are stuck or merely busy, which is the
actual question.

Cluster state for EAP:

```bash
$EAP_HOME/bin/jboss-cli.sh -c --controller=127.0.0.1:<mgmt> \
  --command='/subsystem=jgroups/channel=ee:read-attribute(name=view)'
$EAP_HOME/bin/jboss-cli.sh -c --controller=127.0.0.1:<mgmt> \
  --command='/deployment=<app>.war:read-attribute(name=status)'
```

Also pull the membership view from each node's log independently. The management API and
the log can disagree, and the disagreement is itself the finding.

## Data Grid / Infinispan

Capture server logs, cluster membership, cache configuration and statistics, JGroups
protocol state, Hot Rod/REST endpoint state, and — cross-site — the site status and
cross-site view lines from every node.

Authentication is the usual trap here. The server's health endpoint may answer
anonymously while every real API call requires credentials, so a readiness probe can report
healthy against a server that rejects everything you do next. Verify the credentials on a
**real** cache operation before treating any endpoint result as evidence, and check which
authentication mechanism the server's realm actually accepts rather than assuming.

Record the exact `curl` invocation, including the auth flags, in `commands.log`. An HTTP
transcript without its request line is not evidence.

## OpenShift / Kubernetes

```bash
oc get pods -o wide
oc describe pod <pod>
oc get events --sort-by=.lastTimestamp
oc logs <pod> [-c <container>] [--previous]
oc get deployment,statefulset,svc,route,cm -o yaml
oc get infinispan,<other CRs> -o yaml
oc logs -n <operator-ns> deploy/<operator>
```

`--previous` on a restarting pod is where the actual cause lives. Take the restart reason
from the container status, not from the log tail.

## HTTP transcripts

For every request that is part of the evidence, record the full exchange — method, URL,
request headers including cookies, response status, response headers, body — plus which
backend served it. Which node served the request is the whole content of a failover claim.

```bash
curl -sS -D - -b cookies.txt -c cookies.txt -o body.txt "$URL"
```

## Discipline

- **Copy, never move.** The running system keeps its logs.
- **Quote verbatim.** Anything presented as a log line must exist at the cited path. If you
  cannot find it, write "not present in the capture" — never reconstruct from memory of
  what the product usually prints.
- **Absence is evidence.** "No ERROR on node2 in the failover window" often decides the
  case. Record the window you searched and the grep you ran.
- **Redact** credentials, tokens, keys, certificates. **Keep** hostnames, IPs and ports.
- **Do not parse `.hprof`.** Record path, size, mtime; note it as available for offline
  analysis.
- **Delegate bulk reading.** Anything over a few hundred lines goes to the
  `evidence-analyst` subagent; put its distilled finding in the package, not the file.

## Manifest — `evidence/MANIFEST.txt`

```
<phase>/<file>   <bytes>   <sha256>   <what it shows>   <command that produced it>
```

The manifest is what makes the package auditable by someone who was not here.
