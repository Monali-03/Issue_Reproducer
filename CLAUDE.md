# Red Hat Issue Reproducer — notes for anyone editing these scripts

This repository is a set of **shell reproducers**, not an agent. `run.sh` does not call out
to an AI, and nothing at runtime depends on this file. Read `README.md` first for what the
tool does and `workspaces/<product>/README.md` for how to run one.

These notes exist for whoever changes the code next.

## Structure

Four workspaces, one per product; one driver per product family in `lib/`. The drivers are
version-agnostic — every product-specific fact lives in `workspaces/<product>/workspace.env`.
Adding a product means adding a directory, not editing a driver.

```
workspaces/<product>/run.sh        thin dispatcher: source env, source libs, call flow_*
workspaces/<product>/workspace.env product name, version guard, port block, JDKs, defaults
lib/common.sh                      logging, gates, ports, PIDs, locks, JDK resolution
lib/case.sh                        case parsing, the workspace isolation guard, scenarios
lib/eap.sh lib/datagrid.sh lib/jvm.sh   the drivers
lib/probe.sh lib/fault.sh          the observation and injection libraries
lib/measure.sh lib/plan.sh         the generic engine and the plan it runs
lib/report.sh                      the output package, including SOLUTION.md
lib/flow.sh                        argument parsing and the per-product sequence
```

Six scenarios have hand-written measurement paths. Everything else goes through the generic
engine: probes observed before and after a fault, against a criterion written to the package
*before* the fault is injected. A case the scenario detector has never seen gets a real
measurement instead of a log grep, and `input/plan.env` states one explicitly and outranks
the detected scenario. `reference/measurement-plans.md` is the vocabulary;
`./tools/show-plan.sh <case.txt>` prints what a case would measure without running anything;
`./tools/selftest-measure.sh` guards the decision logic.

## The four rules the output has to satisfy

1. **Run it.** A run that explains how the issue could be reproduced has failed. The
   deliverable is a verdict backed by evidence in the package.
2. **Never guess.** No invented error messages, configuration values, version behaviour,
   stack traces, topology, addresses or bug IDs. Label everything `stated`, `INFERRED` with
   its derivation, or `NOT PROVIDED`. `SOLUTION.md` deliberately contains no KB numbers or
   "fixed in" claims — a remembered version mapping that has drifted costs an hour of
   debugging something that was never the customer's issue.
3. **Verify the harness before trusting the verdict.** Most false reproductions are the
   harness failing, not the product. Hence the startup gates, the mandatory passing
   baseline, and BLOCKED as a first-class outcome (exit 4) distinct from INCONCLUSIVE.
4. **Be honest about the gap.** Everything the lab does differently goes into
   `configuration-diff.txt` via `DEVIATIONS+=(...)`, including the parts that weaken the
   verdict.
5. **The case is authoritative.** Anything the case states — JGroups stack, JDK, node count,
   config — is used as stated, in every scenario. If it cannot be honoured, the run stops
   (BLOCKED, exit 4) with what to install; it does not substitute and carry on behind a
   deviation line. Silent substitution produces a verdict about a system nobody asked about,
   and the deviation gets read after the conclusion has already been believed. `--allow-jdk-
   substitute` is the explicit opt-out. Inference is only for what the case leaves unsaid, and
   is labelled INFERRED.
6. **Never normalise away the fault under test.** The harness makes the lab well-behaved —
   TCPPING instead of multicast, one host instead of three. Every one of those conveniences
   is a fault someone's case is about, and applying it unconditionally means answering a
   question nobody asked while reporting success. `eap_select_stack` keeps the stack the case
   names; the gates run in `measure` mode when the gated condition IS the symptom. Before
   adding a normalisation, ask which case it makes unreproducible.
7. **Measure, never infer — including in the diagnostics.** The multicast probe used to
   return FAIL from the kernel's `MULTICAST` flag without sending a packet. It was wrong in
   both directions (see the multicast entry below) and, being a *diagnostic*, it was trusted.
   A tool built to stop people guessing has to hold its own instruments to the same standard.

## Product traps these scripts already handle

Do not regress these; each one cost a debugging session.

- **javax vs jakarta.** EAP 7.x is Jakarta EE 8 (`javax.*`), EAP 8.x is Jakarta EE 10
  (`jakarta.*`). A `javax` WAR **deploys successfully** on EAP 8 — `WFLYSRV0010: Deployed` —
  and reports healthy while every servlet 404s. Deployment status is never proof; gate 4
  calls the endpoint.
- **A malformed `web.xml` looks the same.** EAP logs `WFLYSRV0010: Deployed` and fails only
  the PARSE phase. `prepare-app.sh` now checks every descriptor for well-formedness before
  building. (`--` is illegal inside an XML comment; that is how this was found.)
- **Per-node `jboss.server.base.dir`.** A port offset alone lets instances fight over
  `data/`, `tmp/`, `log/` and deployment markers.
- **The first glob match is not the right install.** `eap_discover` used to take the first
  tree containing `bin/standalone.sh`. Bash expands a glob in sorted order, so with 8.1.0 and
  8.2.0 both unpacked, an 8.2 case ran on 8.1 — and the major guard (8 == 8) cannot see it.
  Discovery now collects every candidate and picks the one whose **own banner** agrees with
  the case, newest only as the fallback, printing the shortlist when there was more than one.
  A leftover install in `~/Documents/EAP_lab/` is otherwise indistinguishable from the one
  you meant.
- **The directory name is not the version.** `jboss-eap-7.4.0/` here reports
  `Version 7.4.23.GA` — a patched tree. Read `version.txt`, never the basename.
- **Compare versions only as far as both sides state one.** EAP 8.1's banner says `8.1` with
  no micro; a case naming `8.1.0` is not a mismatch against it, and flagging one would put a
  deviation on nearly every EAP 8 run. `eap_version_differs` compares component-wise over the
  shorter of the two, so `7.4.0` vs `7.4.23` differs and `8.1.0` vs `8.1` does not. A
  deviation list that cries wolf stops being read, which costs more than the check saves.
- **Multicast on one host works fine — it is the LAN that drops it.** This entry used to say
  the opposite, and the opposite is measurably false. On this machine `lo` has no `MULTICAST`
  flag and still carries the datagram (the kernel delivers multicast between local sockets
  regardless of the flag), while the flagged wireless interface silently drops it. EAP formed
  a real 3-node udp cluster over `127.0.0.1`. The consequence is the opposite of what the old
  note implied: a single-host lab is *too kind* to a udp case and will refuse to reproduce it.
  `eap_escalate_blocked_multicast` therefore rebinds JGroups to an interface where the probe
  measured a drop, which is the customer's condition. TCPPING is still the right default for
  cases that are not about discovery — but as a normalisation, not because multicast is
  impossible here. On EAP 8.1 `standalone-ha.xml` hardcodes
  `<channel name="ee" stack="udp"/>` with no expression, so `-Djboss.default.jgroups.stack`
  is ignored — the channel's stack is rewritten explicitly and verified in the XML.
- **Cluster views read differently per major.** EAP 7 keeps logging `ISPN000094`; EAP 8 logs
  `WFLYCLJG0033` once, at connect, while the node is still alone, and leaves the management
  API's channel runtime attributes undefined even with statistics enabled. Gate 3 tries the
  management API, then the Infinispan membership lines, and records which source answered.
- **Counting commas in a view line is wrong** — the log timestamp (`15:14:44,619`) and the
  view id both contribute commas. Use `view_size`.
- **Data Grid auth is digest.** The properties realm stores hashed credentials, so Basic is
  rejected with the right password. `/health/status` answers anonymously, so a readiness
  probe against it reports HEALTHY while every real call 403s. REST-created caches are
  permanent.
- **Data Grid's `-o` offset does not move the JGroups bind port** — that comes from
  `-Djgroups.bind.port`.
- **`pgrep -f "<marker>" | head -1` returns the wrapper shell**, not the JVM:
  `standalone.sh` and `server.sh` pass the marker through, and being started first they win
  the lowest PID. Signalling the wrapper leaves the server running. Use `java_pid_for`.
- **PID reuse.** `kill_recorded_pid` re-checks argv immediately before signalling.
  `pkill -f java` has no safe form.
- **The codes a case quotes are not all symptoms.** A customer pastes the line they were
  looking at, and a healthy server logs plenty of those. `WFLYSRV0010: Deployed` is in
  every 404-on-every-path case; `WFLYCLJG0033` is logged once at connect while the node is
  still alone, so a cluster-of-one case quoting it would be "reproduced" by a healthy
  three-node run; `ISPN000094` is logged by every working cluster. `PLAN_BENIGN_CODES` in
  `lib/plan.sh` keeps them as probes and refuses them as criteria. What decides those cases
  is `cluster_view` or `http_status`, not a count.
- **A bare 4xx in a case is usually not an HTTP status.** "Roughly 400 concurrent users at
  peak" became a criterion of `app-status eq 400`. `plan_case_http_status` requires the
  number to appear in an HTTP context.
- **Several quoted exceptions describe one failure.** AND-ing them makes a run that did
  reproduce the symptom report NOT REPRODUCED because the second-order stack trace was not
  logged this time. Criteria in the same group are OR'd; groups are AND'd.
- **`curl -w '%{http_code}'` already prints `000` when nothing answered**, so the habitual
  `|| echo 000` concatenates onto it and yields `000000` — which matches no status pattern,
  so a dead endpoint silently became an unclassifiable one and the load fault reported
  success. Use `|| true` and default the empty case.
- **A fault that did not happen must not produce a negative verdict.** Every `fault_*`
  returns non-zero and sets `FAULT_FAILED_REASON` when it did not inject; the engine turns
  that into INCONCLUSIVE plus a deviation. Note the two different nothings in `fault_load`:
  zero requests attempted means the generator never ran, while every request returning
  `000` means it ran and never reached the server. Both are failures to inject; a 5xx is
  not, because that is the product answering.

## Shell traps that have actually broken this code

All scripts run `set -euo pipefail`. Each of these produced a silent or misleading failure:

- `x="$(grep ...)"` aborts when grep matches nothing — the normal case inside a wait loop.
  Append `|| true`.
- `grep -c` prints `0` **and** exits 1. Needs `|| true` plus a `${n:-0}` default.
- A trailing `(( x == 0 )) && cmd` or `[[ -f f ]] && cmd` as the last statement makes the
  function return 1. Use `if ... fi`, and end report/cleanup functions with `return 0`.
- A bare `wait $pid` aborts the script when the process exited non-zero — which is the
  *expected* outcome for an OOM run. `rc=0; wait "$p" || rc=$?`.
- A `dir/*/` glob that matches nothing expands to itself, and the `[[ -x ]]` test that
  follows then fails.
- `exec 3>&- 2>/dev/null` does not just close fd 3: `exec` with redirections and no command
  applies them to the **whole shell**, so every later error message and xtrace line is
  discarded. This is how a run came to end between two log lines with no reason given.
- `local a="$1" b="${ARR[$a]}"` does not work. The builtin's entire word list is expanded
  before any assignment happens, so `$a` is still unset — and under `set -u` that aborts.
  Split it into two `local` statements.
- `${#ARR[@]:-0}` is not valid substitution syntax. Guard with `declare -p ARR >/dev/null
  2>&1 || return 0` and use `${#ARR[@]}`.
- A function called inside `$( )` must print **only** its result. `dispatch_key` logged an
  `info` line and the dispatch key became the log text, matching no arm of the `case`.
- `local` inside a subshell aborts it: `( local i; ... ) &` is not a function body.
- ERE has no `\-` escape. Use a bracket expression: `[-]Xmx`.
- `eval "$(cmd)"` does not propagate `cmd`'s failure. Capture, check, then eval.
- Poll for a condition with a timeout; never `sleep 30` and hope.

`lib/common.sh` installs an `ERR` trap that names the failing command and its location, so
a `set -e` abort is no longer silent. Keep it.

Run `bash -n` on every file you touch.

## Safety

Destructive operations are allowed against the reproduction environment and nothing else.
`assert_in_pkg` gates every `rm -rf` on the target being inside this run's
`output/<case>-<timestamp>/`. Only recorded PIDs are signalled, argv re-checked first.
`--clean` only signals processes whose command line points into *this* workspace's output
tree. Never target production infrastructure. Full rules in `reference/safety-rules.md`.

## `.claude/`

Left over from an earlier agent-driven version of this tool. Not used by `run.sh`, not read
by anything in `lib/`, safe to delete.
