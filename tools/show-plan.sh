#!/usr/bin/env bash
# show-plan.sh — print the measurement plan a case would get, without starting anything.
#
#   ./tools/show-plan.sh cases/eap7/E7-02-datasource-pool-exhausted/case.txt [node-count]
#
# It answers the question worth asking before a two-hour run: what is this going to measure,
# and is that actually the customer's symptom? The ports and contexts below are a stand-in
# for a real run, so read the shape of the plan, not the numbers.
set -euo pipefail

CASE="${1:-}"
NODE_COUNT="${2:-2}"
[[ -f "$CASE" ]] || { echo "usage: $0 <case.txt> [node-count]" >&2; exit 2; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT/lib"

PKG="$(mktemp -d)"
mkdir -p "$PKG"/{logs,config,nodes} "$PKG"/evidence/{before,during,after}
cp "$CASE" "$PKG/issue.txt"
COMMANDS_LOG="$PKG/commands.log"; : >"$COMMANDS_LOG"
WS_DIR="$PKG"; WS_BIND="127.0.0.1"
export PKG COMMANDS_LOG WS_DIR WS_BIND NODE_COUNT

ts()   { date '+%H:%M:%S'; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   %s\n' "$*"; }
warn() { printf '   warn %s\n' "$*" >&2; }
step() { printf '\n%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
slugify() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40; }
blocked() { printf 'BLOCKED: %s\n' "$*"; exit 4; }

# A plausible stand-in environment, so the plan builder has ports and names to refer to.
product="$(grep -iE '^[[:space:]]*Product[[:space:]]*:' "$CASE" | head -1 || true)"
if grep -qiE 'data ?grid|infinispan|rhdg' <<<"$product"; then
  WS_NAME="datagrid"
  DG_PORTS=(11222 11322); DG_NODES=(dg1 dg2)
  CACHE_NAME="reprocache"; DG_USER="repro"; DG_PASS="repro-Pass1"
  export DG_PORTS DG_NODES CACHE_NAME DG_USER DG_PASS
elif grep -qiE 'jdk|jvm|openjdk|hotspot' <<<"$product"; then
  WS_NAME="jvm"
else
  WS_NAME="eap"
  EAP_HTTP=(8080 8180 8280); EAP_MGMT=(9990 10090); EAP_NODES=(node1 node2 node3)
  APP_CONTEXT="repro"
  export EAP_HTTP EAP_MGMT EAP_NODES APP_CONTEXT
fi
export WS_NAME

source "$LIB_DIR/probe.sh"
source "$LIB_DIR/fault.sh"
source "$LIB_DIR/measure.sh"
source "$LIB_DIR/plan.sh"

printf 'case      : %s\n' "$CASE"
printf 'workspace : %s (assumed from Product:)\n' "$WS_NAME"
printf 'nodes     : %s (pass a second argument to change it)\n' "$NODE_COUNT"

if build_plan; then
  measure_write_plan >/dev/null
  printf '\n'
  cat "$PKG/evidence/measurement-plan.txt"
else
  printf '\nNo plan: nothing in this case is expressible as a before/after observation.\n'
  printf 'The run would fall back to the log-signature reading, which can only tell you\n'
  printf 'whether the error text the case quotes turns up in this run.\n'
fi

rm -rf "$PKG"
