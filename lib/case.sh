#!/usr/bin/env bash
# case.sh — read input/case.txt, enforce that it belongs to THIS workspace, and work out
# which scenario to run.
#
# The product guard is the reason the four workspaces cannot contaminate each other: an
# EAP 8 case dropped into the eap7 workspace is a hard error, not a best-effort run.

# --- field extraction -------------------------------------------------------
# "Key: value" anywhere in the case, first match wins, case-insensitive.
case_field() {
  local key="$1" f="${2:-$CASE_FILE}" v
  v="$(grep -iE "^[[:space:]]*${key}[[:space:]]*:" "$f" 2>/dev/null | head -1 \
       | sed -E "s/^[[:space:]]*[^:]+:[[:space:]]*//" | sed -E 's/[[:space:]]+$//' || true)"
  # Placeholders from the template are absent values, not data.
  [[ "$v" =~ ^\<.*\>$ ]] && v=""
  printf '%s' "$v"
}

# Whole case, lowercased, for keyword matching. CaseParser-style structured extraction
# silently drops anything under an unrecognised heading, so scenario detection reads the
# raw text instead — cache names, site names and step wording live in prose.
case_text() { tr '[:upper:]' '[:lower:]' <"$CASE_FILE"; }
case_has()  { grep -qiE -- "$1" "$CASE_FILE" 2>/dev/null; }

# --- load -------------------------------------------------------------------
load_case() {
  CASE_FILE="$WS_DIR/input/case.txt"
  [[ -f "$CASE_FILE" ]] || blocked "no case file at $CASE_FILE
       Copy $TEMPLATES_DIR/case.txt there and describe the customer's scenario."

  # An untouched template produces a confident reproduction of nothing.
  if ! grep -qiE '^[[:space:]]*(Product|Version)[[:space:]]*:[[:space:]]*[A-Za-z0-9]' "$CASE_FILE" \
     || [[ -z "$(case_field Product)" && -z "$(case_field Version)" ]]; then
    blocked "$CASE_FILE has no Product/Version filled in — it is still the template.
       Fill in at least Product and Version, plus the steps and the actual behaviour."
  fi

  CASE_NUMBER="$(case_field Case)"
  CASE_PRODUCT="$(case_field Product)"
  CASE_VERSION="$(case_field Version)"
  CASE_JDK="$(case_field JDK)"
  CASE_OS="$(case_field OS)"
  CASE_NODES="$(case_field Nodes)"
  CASE_MODE="$(case_field Mode)"
  CASE_DEPLOYMENT="$(case_field Deployment)"
  CASE_FREQUENCY="$(case_field Frequency)"

  CASE_ID="${CASE_NUMBER:-}"
  [[ -z "$CASE_ID" ]] && CASE_ID="$(slugify "${WS_NAME}-${CASE_VERSION:-nover}-$(date +%Y%m%d-%H%M%S)")"
  CASE_ID="$(slugify "$CASE_ID")"
  export CASE_FILE CASE_ID CASE_NUMBER CASE_PRODUCT CASE_VERSION CASE_JDK CASE_OS \
         CASE_NODES CASE_MODE CASE_DEPLOYMENT CASE_FREQUENCY
}

# --- workspace isolation guard ----------------------------------------------
# Each workspace declares WS_PRODUCT_MATCH (a regex) and WS_MAJOR. A case that does not
# match belongs in another workspace and is refused outright.
validate_case_product() {
  local prod="${CASE_PRODUCT:-}" ver="${CASE_VERSION:-}" major=""

  [[ -n "$prod" ]] || blocked "case.txt has no 'Product:' line.
       This workspace only runs '$WS_PRODUCT_LABEL' cases and will not guess."

  # Exclusion runs first. "Red Hat JBoss Data Grid 7.3" would otherwise satisfy a loose EAP
  # pattern and a major-7 check, and run as an application server.
  if [[ -n "${WS_PRODUCT_EXCLUDE:-}" ]] && grep -qiE "$WS_PRODUCT_EXCLUDE" <<<"$prod"; then
    die "PRODUCT MISMATCH — '$prod' is explicitly excluded from the '$WS_NAME' workspace.

       Move the case to the right workspace:
$(suggest_workspace "$prod" "$ver")"
  fi

  if ! grep -qiE "$WS_PRODUCT_MATCH" <<<"$prod"; then
    die "PRODUCT MISMATCH — this case does not belong in the '$WS_NAME' workspace.

       case.txt says:   Product: $prod
       this workspace:  $WS_PRODUCT_LABEL

       Move the case to the right workspace:
$(suggest_workspace "$prod" "$ver")

       Each workspace reads ONLY its own input/, so nothing was read from the others."
  fi

  # Major-version guard. A verdict from the wrong major answers nothing, so this is fatal
  # rather than a warning.
  if [[ -n "${WS_MAJOR:-}" && -n "$ver" ]]; then
    major="$(sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$ver")"
    if [[ -n "$major" && "$major" != "$WS_MAJOR" ]]; then
      die "VERSION MISMATCH — '$WS_NAME' runs $WS_PRODUCT_LABEL (major $WS_MAJOR).

       case.txt says:   Version: $ver  (major $major)

       Move the case to the right workspace:
$(suggest_workspace "$prod" "$ver")

       Configuration schemas, supported JDKs and API namespaces differ between majors;
       running this here would produce a verdict about the wrong product."
    fi
  fi
  ok "case accepted by workspace '$WS_NAME' ($prod ${ver:-version-unstated})"
}

suggest_workspace() {
  local prod="$1" ver="$2" m
  m="$(sed -E 's/^[^0-9]*([0-9]+).*/\1/' <<<"$ver" 2>/dev/null || true)"
  if grep -qiE 'data ?grid|infinispan|rhdg' <<<"$prod"; then
    echo "         → workspaces/datagrid/input/"
  elif grep -qiE 'jdk|jvm|openjdk|hotspot|java' <<<"$prod"; then
    echo "         → workspaces/jvm/input/"
  elif grep -qiE 'eap|wildfly|jboss' <<<"$prod"; then
    case "$m" in
      7) echo "         → workspaces/eap7/input/" ;;
      8) echo "         → workspaces/eap8/input/" ;;
      *) echo "         → workspaces/eap7/input/  (EAP 7.x)"
         echo "         → workspaces/eap8/input/  (EAP 8.x)" ;;
    esac
  else
    echo "         → no workspace matches '$prod'; the four are eap7, eap8, datagrid, jvm"
  fi
}

# --- scenario detection -----------------------------------------------------
# Maps the case text to a reproduction driver. Ordered most specific first: a cross-site
# case also mentions "cache", so the broad patterns must come last.
# "The cluster does not form" is written both ways round — "cluster not forming" and "not
# forming cluster" — and one regex covering every ordering is how this went wrong the first
# time: the combined expression exceeded the regex engine's complexity limit (Fedora's grep
# is ugrep), which is reported on stderr and then matches NOTHING. A silently-empty pattern
# inside an `elif` chain is indistinguishable from an honest miss, and it sent a clustering
# case to 'generic' and an INCONCLUSIVE verdict.
#
# So: three cheap greps chained, each one obviously correct on its own. A line has to carry a
# negation, a cluster word, and a formation verb before it counts. This runs AFTER the
# session-failover branch deliberately — "sessions lost after failover, cluster forms fine"
# contains all three words and belongs to that branch, not this one.
case_cluster_wont_form() {
  case_has 'cluster of one|singleton view|only sees itself|not see each other|two clusters of one' && return 0
  grep -iE -- 'not|never|fail|unable|cannot|can.t' "$CASE_FILE" 2>/dev/null \
    | grep -iE -- 'cluster|view|member' \
    | grep -qiE -- 'form|join|discover' && return 0
  return 1
}

detect_scenario() {
  local s=""
  if   case_has 'cross.?site|relay2|backup site|ispn0004[0-9][0-9]';        then s=xsite
  elif case_has 'session.*(lost|lose|not replicat|disappear|new)|session replicat|failover|fail.?over|sticky|logged out|log(ged)? ?out|new session'; then s=session-failover
  elif case_cluster_wont_form;                                             then s=cluster-formation
  elif case_has 'deadlock|hang|hung|blocked thread|thread.*stuck';          then s=deadlock
  elif case_has 'outofmemory|oom|heap.*(exhaust|grow|leak)|memory leak|gc.*(thrash|overhead)'; then s=memory
  elif case_has 'high cpu|cpu.*(spike|100%)|gc pause|long pause';           then s=cpu-gc
  elif case_has 'ssl|tls|handshake|certificate|keystore|truststore';        then s=tls
  elif case_has 'datasource|connection pool|jdbc|ij000';                    then s=datasource
  elif case_has 'split.?brain|cluster.*(not form|merge)|jgrp|discovery|view'; then s=clustering
  elif case_has 'cache.*(miss|empty|not replicat|lost)|entries.*(lost|miss)'; then s=cache
  elif case_has '404|deploy.*(fail|error)|wflysrv005|not deployed';         then s=deployment
  else s=generic
  fi
  printf '%s' "$s"
}

# Which JGroups stack the case is about, or empty when it does not say.
#
# This matters more than it looks. The harness normally overlays TCPPING onto the tcp stack,
# because multicast between processes on one host does not work and every clustering verdict
# would otherwise be a lab artifact. But when the case says the problem IS the udp stack,
# that overlay repairs the fault before it is measured — the run then reports a healthy
# cluster and answers a question nobody asked. A stack named in the case is the subject under
# test, not a lab detail to normalise away.
detect_stack() {
  local s=""
  if   case_has 'udp stack|stack[^a-z0-9]{0,3}udp|multicast|mping|udp.?based|over udp|using udp|with udp'; then s=udp
  elif case_has 'tcpping|jdbc.?ping|dns.?ping|tcp stack|stack[^a-z0-9]{0,3}tcp|using tcp';                 then s=tcp
  fi
  printf '%s' "$s"
}

# Node count: the case, else the workspace default. Marked INFERRED when defaulted.
detect_node_count() {
  local n=""
  n="$(grep -oiE '([0-9]+)[[:space:]]*(node|server|instance|pod)s?' "$CASE_FILE" 2>/dev/null \
       | head -1 | grep -oE '[0-9]+' || true)"
  [[ -z "$n" ]] && n="$(grep -oE '[0-9]+' <<<"${CASE_NODES:-}" | head -1 || true)"
  if [[ -z "$n" || "$n" -lt 1 ]]; then
    printf '%s' "$WS_DEFAULT_NODES"; return
  fi
  (( n > 5 )) && n=5      # lab ceiling; recorded as a deviation in the config diff
  printf '%s' "$n"
}

# Provenance label so the report can distinguish a stated fact from a derived one.
field_or() {
  local val="$1" fallback="$2" label="$3"
  if [[ -n "$val" ]]; then printf '%s|stated' "$val"
  else printf '%s|INFERRED (%s)' "$fallback" "$label"; fi
}
