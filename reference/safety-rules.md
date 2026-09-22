# Safety rules (spec §6)

The agent operates the reproduction environment freely. It never touches production.

Reproductions involve genuinely destructive steps — killing nodes, wiping data
directories, blocking traffic — because that is what the customer's scenario is. The
danger is not the operation; it is the operation landing on the wrong target. Every rule
below exists to pin the target.

---

## Authorized targets

An operation is permitted only against:

1. `$PKG` — this run's package directory under `output/`, and everything inside it
   (including the per-node server base directories).
2. A product installation listed in `reference/lab-targets.txt` as a lab install.
3. A container, pod or namespace this run created.
4. A target the user named explicitly in this conversation as a reproduction environment.

Anything else is out of scope. If you are unsure which category a path is in, it is not
authorized — ask.

`reference/lab-targets.txt` is the allow-list. It is owned by the user; the agent reads it
and may propose additions, but does not add entries on its own.

---

## Confirmation gate

Before `rm -rf`, `kill` / `pkill` / `killall`, `shutdown`, `reboot`, `systemctl stop`,
`iptables` / `nft` / `firewall-cmd`, `tc`, `truncate`, `mkfs`, `dd`, a database `DROP`, or
any `oc delete` / `kubectl delete`, state to yourself and in `commands.log`:

```
DESTRUCTIVE OPERATION
  Command:     <exact command>
  Target:      <path | PID | resource>
  Authorized:  <which of the four categories above, and why>
  Reversible:  <yes — reseeded by setup.sh | no>
```

If the "Authorized" line cannot be completed from the four categories, do not run the
command. Ask the user.

---

## Process rules

**Only kill PIDs this run recorded.** `start.sh` writes `<label>.pid` for every process it
starts. A kill target must come from one of those files, and you must confirm the PID is
still the process you started — PIDs are reused, and killing a recycled PID takes out
something unrelated.

```bash
pid="$(cat "$PKG/node1.pid")"
ps -p "$pid" -o args= | grep -q "jboss.node.name=node1" || { echo "PID reuse — refusing"; exit 1; }
kill "$pid"
```

**Never `pkill -f java`, `pkill -f standalone.sh`, or `killall java`.** A broad pattern kills
the user's IDE, their other servers, and any unrelated JVM on the box. This has no safe
form; there is always a PID file.

**Kill the server, not the wrapper.** `standalone.sh` and `server.sh` fork a JVM. Killing
the wrapper leaves the JVM orphaned — still bound to its port, still serving requests — so
the failover step silently never happens and the run produces a confident, wrong verdict.
Match the server JVM's own argv (`-Djboss.node.name=`, `-n <name> -s <root>`).

---

## Filesystem rules

- Deletions are confined to `$PKG`. The product installation is read-only to this agent;
  per-node state lives in copies under `$PKG`.
- Never delete a path built from an unset variable. `rm -rf "$BASE/data"` with `BASE` empty
  is `rm -rf /data`. Use `set -u`, and guard:
  `[[ -n "${BASE:-}" && "$BASE" == "$PKG"/* ]] || exit 1`
- `cleanup.sh` removes only what this run created. It never removes the case input, the
  collected evidence, or the product installation.

---

## Network rules

Firewall and traffic-shaping changes affect the whole host, not just the reproduction.

- Prefer an application-level stand-in — a proxy you control in front of the nodes — over
  host firewall rules. It is scoped, it needs no privilege, and it is reversible by
  stopping a process.
- A proxy stand-in also models the failure better. To simulate a network partition you need
  *silence*: hold the sockets open and stop forwarding. Killing a process or dropping a
  connection sends FIN or RST, the peer detects it immediately, and you have reproduced a
  clean shutdown rather than a partition — usually the opposite of the customer's scenario.
- If host-level rules are genuinely required: capture the current ruleset first, apply a
  scoped rule to specific ports, register a trap to restore on exit, and tell the user what
  you changed. Never flush a chain.

---

## Container and OpenShift rules

- Confirm the context before every mutating command: `oc whoami`, `oc project`. State the
  cluster and namespace in `commands.log`.
- Operate only in a namespace this run created or the user named. Never a namespace you
  found by listing.
- `oc delete` is scoped to labelled resources this run created. Never `--all`, never a
  bare namespace delete unless the user named that namespace as disposable.
- Container images are pulled, never pushed.

---

## Credentials

- Never write a real credential into the package. Secrets and datasource passwords are
  placeholders.
- Redact credentials, tokens, keys and certificates from collected evidence. Keep
  hostnames, IPs and ports — topology is the point of the capture.
- Never commit anything from `output/` to git.

---

## When the environment is not clearly a lab

Stop and ask. The cost of one question is a few seconds. The cost of being wrong is
someone's production cluster, and there is no undo.
