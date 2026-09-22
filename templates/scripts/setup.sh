#!/usr/bin/env bash
# setup.sh — resolve the runtime, seed per-node state, build the app, apply config.
# Idempotent: safe to re-run. Touches nothing outside the package except reading the
# product installation.
#
# TEMPLATE. The generator fills the marked sections for the specific case.

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

info "=== setup: $TARGET_PRODUCT $TARGET_VERSION (JDK $TARGET_JDK) ==="

# --- 1. JDK ----------------------------------------------------------------
# Resolve a JDK matching TARGET_JDK. Search JAVA_HOME, then the usual roots. Do not
# silently fall back to whatever `java` happens to be — an unsupported JDK makes the
# server die at boot for reasons that have nothing to do with the customer's issue.
resolve_jdk() {
  local want="$TARGET_JDK" cand v
  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    v="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
    [[ "$v" == *"\"$want"* ]] && { echo "$JAVA_HOME"; return 0; }
    warn "JAVA_HOME is $v but the case needs JDK $want — searching"
  fi
  for cand in /usr/lib/jvm/*"$want"* "$HOME"/jdks/*"$want"* /opt/jdk*"$want"*; do
    [[ -x "$cand/bin/java" ]] || continue
    echo "$cand"; return 0
  done
  return 1
}

if JAVA_HOME="$(resolve_jdk)"; then
  export JAVA_HOME
  info "JDK: $JAVA_HOME ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))"
else
  die "no JDK $TARGET_JDK found. Install one, or set JAVA_HOME in nodes.env.
       This host's JDKs: $(ls -d /usr/lib/jvm/* 2>/dev/null | tr '\n' ' ')"
fi

# --- 2. product installation ------------------------------------------------
# Autodiscover when EAP_HOME is unset, and hard-fail on a major mismatch.
# Note: distribution archives often extract into a nested directory, so the real home
# may be one level below the obvious path — probe for the launcher, not the name.
resolve_home() {
  [[ -n "${EAP_HOME:-}" ]] && { echo "$EAP_HOME"; return 0; }
  local root d
  IFS=':' read -ra roots <<<"$SEARCH_PATHS"
  for root in "${roots[@]}"; do
    while IFS= read -r d; do
      [[ -x "$d/bin/standalone.sh" ]] && { echo "$d"; return 0; }
    done < <(find "$root" -maxdepth 4 -type d -name "jboss-eap-${TARGET_MAJOR}*" 2>/dev/null)
  done
  return 1
}

EAP_HOME="$(resolve_home)" || die "no $TARGET_PRODUCT $TARGET_MAJOR.x installation found under $SEARCH_PATHS.
       Set EAP_HOME in nodes.env. BLOCKED — cannot reproduce without the product."
export EAP_HOME
[[ -x "$EAP_HOME/bin/standalone.sh" ]] || die "not a valid install: $EAP_HOME"

# Version verification: the installation's own metadata outranks the directory name.
INSTALLED_VERSION="$(cat "$EAP_HOME/version.txt" 2>/dev/null || echo UNKNOWN)"
info "EAP_HOME: $EAP_HOME"
info "installed version: $INSTALLED_VERSION (case asks for $TARGET_VERSION)"
if [[ "$INSTALLED_VERSION" != *"$TARGET_VERSION"* ]]; then
  warn "VERSION MISMATCH — the verdict will be about $INSTALLED_VERSION, not $TARGET_VERSION."
  warn "Record this in configuration-diff.txt. Apply the matching CP for a valid verdict."
fi

# --- 3. per-node state ------------------------------------------------------
# Each node gets its own server base directory. A port offset alone is NOT enough:
# instances sharing a base fight over data/, tmp/, log/ and deployment markers, and
# the resulting corruption looks exactly like a product bug.
for name in $(node_names); do
  base="$(node_base "$name")"
  assert_in_pkg "$base"
  if [[ -d "$base" ]]; then
    info "reseeding $name base dir"
    rm -rf "${base:?}"
  fi
  mkdir -p "$base"
  cp -r "$EAP_HOME/standalone/configuration" "$base/"
  mkdir -p "$base"/{deployments,data,tmp,log}
  info "seeded $base from stock standalone/"
done

# --- 4. application ---------------------------------------------------------
# The blueprint is chosen from the case by the build-test-app skill and recorded in
# nodes.env as APP_BLUEPRINT:
#   session-cluster  clustering / session failover  (WAR, <distributable/>)
#   simple-web       everything non-clustered       (WAR)
#   cache-harness    Data Grid server               (REST driver, no WAR)
#
# prepare-app.sh picks javax.* vs jakarta.* from TARGET_MAJOR. Getting that wrong does
# not fail the build OR the deployment — the WAR deploys cleanly and every servlet 404s.
# Hence gate 4 in start.sh, which calls the endpoint instead of reading a status.
APP_BLUEPRINT="${APP_BLUEPRINT:-session-cluster}"

if [[ "$APP_BLUEPRINT" == "cache-harness" ]]; then
  info "app: cache-harness (no WAR — REST driver against the Data Grid server)"
  mkdir -p "$PKG_DIR/app"
  cp -r "$PKG_DIR/../../templates/apps/cache-harness/." "$PKG_DIR/app/" 2>/dev/null \
    || warn "cache-harness templates not found — copy them into app/ manually"
  chmod +x "$PKG_DIR/app/cache-harness.sh" 2>/dev/null || true

elif [[ -n "${CUSTOMER_WAR:-}" && -f "$CUSTOMER_WAR" ]]; then
  # The customer's own deployment is higher fidelity than anything we can write.
  info "app: using the customer-supplied deployment $CUSTOMER_WAR"
  for name in $(node_names); do
    cp "$CUSTOMER_WAR" "$(node_base "$name")/deployments/"
  done

else
  info "app: building blueprint '$APP_BLUEPRINT' (major=$TARGET_MAJOR, jdk=$TARGET_JDK)"
  prep="$PKG_DIR/../../templates/apps/prepare-app.sh"
  [[ -x "$prep" ]] || die "prepare-app.sh not found at $prep"
  TARGET_MAJOR="$TARGET_MAJOR" TARGET_JDK="$TARGET_JDK" APP_NAME="$APP_NAME" \
    run_cmd BUILD "$prep" "$APP_BLUEPRINT" "$PKG_DIR/app"

  war="$(find "$PKG_DIR/app/target" -maxdepth 1 -name '*.war' | head -1)"
  [[ -n "$war" ]] || die "no WAR produced — cannot deploy. BLOCKED."
  for name in $(node_names); do
    cp "$war" "$(node_base "$name")/deployments/"
    info "deployed $(basename "$war") → $name"
  done
fi

# --- 5. configuration -------------------------------------------------------
# GENERATOR: apply the case's configuration to each node base dir.
# Prefer jboss-cli.sh --file= over hand-edited XML — it survives version drift and
# self-documents. Never edit the shared installation; only the per-node copies.
for name in $(node_names); do
  cfg="$PKG_DIR/config/eap/$name.cli"
  [[ -f "$cfg" ]] || continue
  info "GENERATOR: apply $cfg to $name (offline CLI or pre-edited XML)"
done

# --- 6. load balancer -------------------------------------------------------
if [[ "$LB_ENABLED" == "true" ]]; then
  info "GENERATOR: render config/lb/ for the balancer, backends from NODES, sticky=$LB_STICKY"
fi

info "=== setup complete ==="
info "next: ./scripts/start.sh"
