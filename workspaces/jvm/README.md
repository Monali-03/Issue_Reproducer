# jvm — OpenJDK / HotSpot reproducer

Reproduces **JVM-level** issues: OutOfMemoryError, Java-level deadlock, high CPU, long GC
pauses. There is no application server here — the subject is the JVM itself, running the
customer's own flags. This workspace reads only its own `input/` and writes only its own
`output/`.

## 1. Drop the case in

```
workspaces/jvm/input/
├── case.txt            ← the customer's scenario (REQUIRED)
├── configs/            ← standalone.conf, jvm.options, java.opts — THE FLAGS
├── logs/               ← gc.log, console output, hs_err_pid*.log
├── dumps/              ← thread dumps, heap dumps
└── attachments/        ← anything else they sent
```

`input/case.txt` is a filled-in copy of `templates/case.txt`. Two lines decide everything
and are not optional:

```
Product: OpenJDK
JDK:     17
```

**Supply the customer's JVM flags.** Heap size and collector choice decide almost every
issue in this class, so a run without them is answering a different question. The flags are
taken, in order, from `input/configs/jvm*.txt`, `*.conf` or `java*.opts`; then from any
`-X`/`-XX` options written in `case.txt`; and only then from a default, which is recorded as
the largest fidelity gap in the run. They are used **verbatim** — rewriting them would
reproduce a configuration nobody runs.

## 2. Run it

```bash
cd workspaces/jvm
./run.sh
```

| flag | effect |
|---|---|
| `--scenario NAME` | override scenario detection (`memory`, `deadlock`, `cpu-gc`) |
| `--allow-jdk-substitute` | run on a different JDK than the case names (see below) |
| `--clean` | kill anything this workspace left running, then exit |

Tunables, as environment variables: `WS_DURATION` (default 180s), `WS_THREADS` (4),
`WS_SAMPLES` (6), `WS_SAMPLE_GAP` (10s), `WS_PAUSE_THRESHOLD_MS` (1000).

```bash
WS_DURATION=600 WS_THREADS=16 ./run.sh
```

The run resolves the JDK, compiles the workload **with that JDK**, starts it under the
customer's flags, waits for it to actually be working, samples the live process, and reads
the verdict off the samples rather than off the log wording.

There is no product to install here — the JDK *is* the subject. But it has to be the major
version the case names, and this workspace will not substitute another one, so install it
first: `dnf install java-17-openjdk-devel`, or unpack a tarball JDK into `~/jdks/`.
`$JAVA_HOME`, `/usr/lib/jvm/*/`, `~/jdks/*/`, `/opt/jdk*/` and `/opt/java/*/` are searched,
in that order. A missing JDK ends the run `BLOCKED` with every JDK it did find listed;
`--allow-jdk-substitute` overrides that and heads the deviation list with the substitution.

## 3. What comes out

`output/<case>-<timestamp>/`, with `output/latest` pointing at the most recent run:

| file | what it is |
|---|---|
| `VERDICT.txt` | REPRODUCED / NOT REPRODUCED / INCONCLUSIVE / BLOCKED, and why |
| `SOLUTION.md` | ranked candidate causes, each with a check command and a fix |
| `README.md` | the run written up, in the order someone else would re-run it |
| `logs/workload.log` | the workload's stdout and stderr |
| `logs/gc.log` | GC log, in the spelling the target JDK understands |
| `evidence/before/vm-flags.txt` | `VM.flags -all` — what the JVM actually ran with |
| `evidence/before/jvm-default-flags.txt` | `-XX:+PrintFlagsFinal` for comparison |
| `evidence/during/threaddump-N.txt` | `jcmd Thread.print -l`, taken while the symptom is live |
| `evidence/during/heap-N.txt` | `jcmd GC.heap_info` per sample |
| `evidence/during/ps-samples.txt` | `%CPU` and RSS over time |
| `evidence/during/heapdump.hprof` | on OOM, if the flags did not already set a path |
| `evidence/after/cpu-gc-measurements.txt` | longest pause and average CPU against the threshold |
| `../<case>-<timestamp>.tar.gz` | the package minus heap dumps — this is what you attach |

## Ports it uses

None. It can run alongside any of the other three workspaces.

## What it will not do

- **It will not run another product's case.** An EAP or Data Grid case in this folder is a
  hard error naming the folder it belongs in.
- **It will not quietly change the JDK.** A JVM-level symptom is version-specific, so if the
  JDK the case names is not installed the run stops rather than answering about a different
  one. `--allow-jdk-substitute` overrides that, and puts the substitution at the top of the
  deviation list: the verdict then describes *that* JDK and does not transfer to the
  customer's without further checking.
- **It will not call a thread state a deadlock.** The verdict comes from the JVM's own
  detector — `Found one Java-level deadlock` in a live thread dump — or it is NOT
  REPRODUCED. If no dump could be taken at all, it is INCONCLUSIVE, which is a distinct
  outcome from "did not happen".
- **It will not guess.** Anything the case does not state is marked `INFERRED` with its
  derivation, or `NOT PROVIDED`. No bug IDs, KB numbers or "fixed in" claims are ever
  emitted.

## The workload

`templates/apps/jvm-workload/ReproWorkload.java` — plain Java, no build tool, modes
`leak` / `deadlock` / `cpu` / `alloc` / `idle`, selected from the detected scenario. Leak
mode retains through a static list, so it is genuine retention rather than allocation the
collector can reclaim. Sampling does not start until the workload prints `WORKLOAD_READY`,
so no sample describes JVM startup instead of the symptom.
