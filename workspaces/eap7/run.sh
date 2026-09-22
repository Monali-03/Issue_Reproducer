#!/usr/bin/env bash
# JBoss EAP 7.x reproducer. Run it from this directory:  ./run.sh
# Reads ONLY this workspace's input/ and writes ONLY this workspace's output/.
set -euo pipefail

WS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export WS_DIR
# shellcheck source=workspace.env
source "$WS_DIR/workspace.env"
# shellcheck source=../../lib/common.sh
source "$WS_DIR/../../lib/common.sh"
source "$LIB_DIR/case.sh"
source "$LIB_DIR/report.sh"
source "$LIB_DIR/diagnose.sh"
source "$LIB_DIR/probe.sh"
source "$LIB_DIR/fault.sh"
source "$LIB_DIR/measure.sh"
source "$LIB_DIR/plan.sh"
source "$LIB_DIR/eap.sh"
source "$LIB_DIR/flow.sh"

flow_eap "$@"
