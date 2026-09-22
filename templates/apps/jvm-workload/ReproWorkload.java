// ReproWorkload — the load used by the jvm workspace to provoke a JVM-level symptom
// under the customer's own flags.
//
// Deliberately plain Java (no framework, no build tool): it is compiled with javac from
// whichever JDK the reproduction targets, so the JDK under test is the only variable.
//
//   --mode leak|deadlock|cpu|alloc|idle
//   --duration <seconds>      wall-clock budget (default 120)
//   --threads <n>             worker threads (default 4)
//   --chunk <kb>              allocation size per step (default 512)
//   --rate <ms>               pause between allocation steps (default 5)
//
// Everything it does is printed with a timestamp so the reproduction log can be read
// against the GC log and the thread dumps on the same timeline.

import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

public class ReproWorkload {

    // Static so the leak mode is a genuine unreachable-by-GC retention, not a local that
    // escape analysis or a scope exit would quietly release.
    private static final List<byte[]> RETAINED = new ArrayList<byte[]>();
    private static final AtomicLong ALLOCATED_KB = new AtomicLong();
    private static final SimpleDateFormat TS = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS");

    private static String mode = "idle";
    private static int durationSec = 120;
    private static int threads = 4;
    private static int chunkKb = 512;
    private static int rateMs = 5;

    public static void main(String[] args) throws Exception {
        parse(args);
        log("workload starting: mode=" + mode + " duration=" + durationSec + "s threads=" + threads
                + " chunk=" + chunkKb + "KB rate=" + rateMs + "ms");
        log("pid=" + pid() + " java=" + System.getProperty("java.version")
                + " vendor=" + System.getProperty("java.vendor"));
        log("max heap=" + (Runtime.getRuntime().maxMemory() / 1048576) + "MB");
        log("jvm args=" + ManagementFactory.getRuntimeMXBean().getInputArguments());

        // A marker the driver waits for: it must not start sampling before the workload is
        // genuinely running, or the samples describe JVM startup instead of the symptom.
        log("WORKLOAD_READY");

        long deadline = System.currentTimeMillis() + durationSec * 1000L;
        if ("leak".equals(mode))          runLeak(deadline);
        else if ("deadlock".equals(mode)) runDeadlock(deadline);
        else if ("cpu".equals(mode))      runCpu(deadline);
        else if ("alloc".equals(mode))    runAlloc(deadline);
        else                              runIdle(deadline);

        log("WORKLOAD_COMPLETE allocated=" + ALLOCATED_KB.get() + "KB");
        System.exit(0);
    }

    // --- leak: retain everything, so the heap can only go one way ---------------
    private static void runLeak(long deadline) {
        MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
        long lastReport = 0;
        try {
            while (System.currentTimeMillis() < deadline) {
                synchronized (RETAINED) { RETAINED.add(new byte[chunkKb * 1024]); }
                ALLOCATED_KB.addAndGet(chunkKb);
                if (System.currentTimeMillis() - lastReport > 5000) {
                    lastReport = System.currentTimeMillis();
                    long used = mem.getHeapMemoryUsage().getUsed() / 1048576;
                    long max = mem.getHeapMemoryUsage().getMax() / 1048576;
                    log("heap used=" + used + "MB / max=" + max + "MB retained=" + RETAINED.size() + " chunks");
                }
                sleep(rateMs);
            }
            // Reaching the deadline without an OOM is a real result, not a failure: it says
            // the heap absorbed the retention for this long. The driver reports it as such.
            log("WORKLOAD_SURVIVED heap did not exhaust within " + durationSec + "s");
        } catch (OutOfMemoryError e) {
            // Printed, not swallowed. The driver greps for this exact token.
            log("WORKLOAD_OOM java.lang.OutOfMemoryError: " + e.getMessage());
            System.err.println("java.lang.OutOfMemoryError: " + e.getMessage());
            e.printStackTrace();
            System.exit(137);
        }
    }

    // --- deadlock: two locks, two threads, opposite order -----------------------
    private static void runDeadlock(long deadline) throws Exception {
        final Object lockA = new Object();
        final Object lockB = new Object();
        Thread t1 = new Thread(new Runnable() {
            public void run() {
                synchronized (lockA) {
                    log("thread-1 holds lockA, wants lockB");
                    sleep(500);
                    synchronized (lockB) { log("thread-1 got both (no deadlock)"); }
                }
            }
        }, "repro-deadlock-1");
        Thread t2 = new Thread(new Runnable() {
            public void run() {
                synchronized (lockB) {
                    log("thread-2 holds lockB, wants lockA");
                    sleep(500);
                    synchronized (lockA) { log("thread-2 got both (no deadlock)"); }
                }
            }
        }, "repro-deadlock-2");
        t1.start(); t2.start();
        log("WORKLOAD_DEADLOCK_ARMED both threads started");
        // Hold the process open so the driver can take thread dumps against it; the two
        // workers are expected never to finish.
        while (System.currentTimeMillis() < deadline) sleep(500);
        log("deadlock window closed (threads alive: t1=" + t1.isAlive() + " t2=" + t2.isAlive() + ")");
    }

    // --- cpu: saturate n threads ------------------------------------------------
    private static void runCpu(final long deadline) throws Exception {
        List<Thread> ts = new ArrayList<Thread>();
        for (int i = 0; i < threads; i++) {
            Thread t = new Thread(new Runnable() {
                public void run() {
                    double x = 1.0;
                    while (System.currentTimeMillis() < deadline) {
                        for (int j = 0; j < 100000; j++) x = Math.sqrt(x * 1.0000001 + j);
                    }
                    if (x == 42.0) log("unreachable");   // keeps the loop from being optimised away
                }
            }, "repro-cpu-" + i);
            t.start(); ts.add(t);
        }
        log("WORKLOAD_CPU_BUSY " + threads + " threads spinning");
        for (Thread t : ts) t.join();
    }

    // --- alloc: churn without retaining, to exercise GC -------------------------
    private static void runAlloc(final long deadline) throws Exception {
        List<Thread> ts = new ArrayList<Thread>();
        for (int i = 0; i < threads; i++) {
            Thread t = new Thread(new Runnable() {
                public void run() {
                    while (System.currentTimeMillis() < deadline) {
                        byte[] b = new byte[chunkKb * 1024];
                        b[0] = 1;                       // force the allocation to be real
                        ALLOCATED_KB.addAndGet(chunkKb);
                        sleep(rateMs);
                    }
                }
            }, "repro-alloc-" + i);
            t.start(); ts.add(t);
        }
        log("WORKLOAD_ALLOC_CHURN " + threads + " threads allocating");
        for (Thread t : ts) t.join();
    }

    private static void runIdle(long deadline) {
        log("WORKLOAD_IDLE holding the JVM open so its flags and GC behaviour can be sampled");
        while (System.currentTimeMillis() < deadline) sleep(1000);
    }

    // --- helpers ----------------------------------------------------------------
    private static void parse(String[] a) {
        for (int i = 0; i < a.length - 1; i++) {
            if ("--mode".equals(a[i]))          mode = a[++i];
            else if ("--duration".equals(a[i])) durationSec = Integer.parseInt(a[++i]);
            else if ("--threads".equals(a[i]))  threads = Integer.parseInt(a[++i]);
            else if ("--chunk".equals(a[i]))    chunkKb = Integer.parseInt(a[++i]);
            else if ("--rate".equals(a[i]))     rateMs = Integer.parseInt(a[++i]);
        }
    }

    private static String pid() {
        String n = ManagementFactory.getRuntimeMXBean().getName();
        int at = n.indexOf('@');
        return at > 0 ? n.substring(0, at) : n;
    }

    private static void sleep(long ms) {
        if (ms <= 0) return;
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    private static void log(String m) {
        System.out.println("[" + TS.format(new Date()) + "] " + m);
        System.out.flush();
    }
}
