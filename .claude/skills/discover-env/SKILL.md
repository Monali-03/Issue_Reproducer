---
name: discover-env
description: Inventory the reproduction host before changing anything - OS, arch, CPU, memory, disk, kernel, installed JDKs, container and cluster tooling, build tools, network interfaces, free ports, and installed Red Hat products (EAP, JWS, JBCS, Data Grid). Writes environment.txt. Use as the second stage of a reproduction, or standalone to answer "what can this box run?".
---

# Discover — environment inventory

Read the host before you touch it. Two purposes: prove the reproduction is feasible here,
and record the baseline in `environment.txt` so the run is interpretable later.

**Read-only.** This stage installs nothing and changes nothing.

Run the independent probes in parallel — they do not depend on each other. Do not run
probes irrelevant to the case: skip the OpenShift block entirely for a local EAP session
case.

## Host

```bash
uname -a
cat /etc/os-release
lscpu | head -20
free -h
df -h .
ulimit -a | grep -E 'open files|processes'
```

Note the OS delta against the customer's. A RHEL 8 case reproduced on Fedora is usually
fine, but it is a config-diff entry, and it matters for anything touching glibc, the
kernel network stack, crypto policy (`update-crypto-policies --show`) or SELinux
(`getenforce`).

## Java

Every JDK on the box, not just the one on `$PATH`:

```bash
java -version 2>&1
echo "JAVA_HOME=$JAVA_HOME"
ls -d /usr/lib/jvm/* ~/jdks/* /opt/jdk* 2>/dev/null
for j in <each found>; do "$j/bin/java" -version 2>&1 | head -1; done
```

For JVM-related cases also capture, from the JDK that will actually run the product:

```bash
java -XshowSettings:properties -version 2>&1
java -XX:+PrintFlagsFinal -version | grep -E 'MaxHeapSize|UseG1GC|UseParallelGC|UseZGC'
```

Then check the JDK against the product's supported set. A version the product does not
support is a blocker to raise now, not a puzzle to debug at startup.

## Tooling

```bash
podman --version; docker --version
oc version --client; kubectl version --client
mvn -version; git --version
curl --version | head -1; ab -V 2>&1 | head -1; siege --version 2>&1 | head -1
httpd -v 2>/dev/null || apachectl -v 2>/dev/null
```

Only the ones the case needs.

## Installed Red Hat products

Search the usual roots and report each install with its resolved version:

```bash
ls -d ~/Documents/*/ /opt/* /usr/share/jbossas /opt/rh/* 2>/dev/null
find "$HOME" /opt -maxdepth 4 -name 'version.txt' -path '*jboss*' 2>/dev/null
find "$HOME" /opt -maxdepth 4 -type d \( -name 'jboss-eap-*' -o -name '*datagrid*server*' \
  -o -name 'jws-*' -o -name 'tomcat*' \) 2>/dev/null
```

Read the version from each install's own metadata (`version.txt`, `bin/product.conf`, the
modules product layer) rather than trusting the directory name. Distribution archives often
extract into a nested directory, so the real `*_HOME` may be one level below what the path
suggests — verify by checking for `bin/standalone.sh` (EAP) or `bin/server.sh` (Data Grid).

If the version the case needs is not installed, that is a **BLOCKED** finding to report
immediately, along with what *is* available and whether the gap can be closed (a patch
applied to a GA install, a container image pulled, a Temurin JDK downloaded).

## Network

```bash
ip -br addr
ip -br link                 # note which interfaces carry MULTICAST
ss -tulpn | awk '{print $5}' | grep -oE '[0-9]+$' | sort -un
```

Check the ports the plan needs are free — the whole set, including offsets for multi-node
runs, management ports, and JGroups ports. A port clash discovered at startup costs a
restart.

For clustering cases, record whether multicast is actually usable on the interface you will
bind to. Loopback typically is not, and container/VPN interfaces often are not — which
decides whether the plan can use a multicast-based discovery protocol or must use a
static/unicast one. Determine this from `ip -br link` flags and a real test, not from
assumption.

## Output — `$PKG/environment.txt`

```
ENVIRONMENT DISCOVERY
Collected: <ISO-8601 timestamp>   Host: <hostname>   User: <user>

OS / KERNEL / ARCH / CPU / MEMORY / DISK / SELINUX / CRYPTO POLICY
JAVA
  <path> → <version>   [SUPPORTED for <product> <ver> | NOT SUPPORTED | UNVERIFIED]
TOOLING
INSTALLED PRODUCTS
  <path> → <version from metadata>
NETWORK
  interfaces, multicast capability, ports required vs free
DELTA VS CUSTOMER
  <field>: customer <x> / lab <y> — <impact or "none">
FEASIBILITY
  READY | BLOCKED: <what is missing and how it could be obtained>
```

Raw command output goes to `$PKG/evidence/before/` — `environment.txt` is the digest.
