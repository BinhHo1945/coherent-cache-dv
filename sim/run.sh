#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <project_dir> <top_module> [extra vlog args, e.g. +define+VERIF_LIC]"
  exit 1
fi

PROJ="$1"; TOP="$2"; shift 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source ./env.sh

WORKDIR="$ROOT/work/$PROJ"
mkdir -p "$WORKDIR" "$ROOT/reports"

# Collect sources: common first, then the project's rtl and tb
FILES=$(find common "$PROJ/rtl" "$PROJ/tb" -name '*.sv' -o -name '*.v' 2>/dev/null | sort)
if [ -z "$FILES" ]; then
  echo "No source files found for $PROJ"; exit 1
fi

vlib "$WORKDIR"
vlog -sv -work "$WORKDIR" +cover=bcesf "$@" $FILES
vsim -c -work "$WORKDIR" -coverage ${VSIM_ARGS:-} "$TOP" \
     -do "run -all; coverage save -onexit $WORKDIR/cov.ucdb; quit -f" \
     | tee "$ROOT/reports/${PROJ}_run.log"