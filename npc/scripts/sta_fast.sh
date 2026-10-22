#!/usr/bin/env bash
# Fast STA: synthesis + post-synthesis STA only.
# Additive helper for `make sta-fast`; it does not touch the full backend flow.
set -euo pipefail

NPC_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${FAST_BACKEND_DIR:-"$NPC_DIR/build/backend_fast"}
WS=${FAST_WS:-fast}
FREQ=${FREQ_MHZ:-100.0}
REPO_DIR=$(cd "$NPC_DIR/.." && pwd)

RUN_ID=${RUN_ID:-"$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)_$(date +%Y%m%d_%H%M%S)"}
RUN_DIR="$NPC_DIR/build/sta_fast/$RUN_ID"
mkdir -p "$RUN_DIR"

# Yosys ABC strategy (DELAY 0-13, AREA 0-12, BALANCE 0-7).  Export it so
# ECC/Yosys can pick it up from the environment; the generated synthesis
# script reads $env(YOSYS_SYNTH_STRATEGY).
STRATEGY=${YOSYS_SYNTH_STRATEGY:-"DELAY 4"}
export YOSYS_SYNTH_STRATEGY="$STRATEGY"

echo "[sta-fast] run_id=$RUN_ID freq=${FREQ}MHz strategy=${STRATEGY}"
echo "[sta-fast] project=$BUILD workspace=$WS"
echo "[sta-fast] log=$RUN_DIR/run.log"

# Fast mode uses the syn_sta preset (Synth only); --only cannot be combined
# with --overwrite (ECC returns selector_requires_workspace), so run the
# preset flow and let --overwrite create a fresh workspace.
if [ -d "$BUILD/$WS" ]; then
  rm -rf "$BUILD/$WS"
fi
START_NS=$(date +%s%N)
if ! ecc run --project "$BUILD" --workspace "$WS" --overwrite \
      2>&1 | tee "$RUN_DIR/run.log"; then
  echo "[sta-fast] ERROR: ECC run failed. Last 60 log lines:"
  tail -60 "$RUN_DIR/run.log" || true
  exit 1
fi
END_NS=$(date +%s%N)
ELAPSED_S=$(( (END_NS - START_NS) / 1000000000 ))
printf 'elapsed_s=%s\n' "$ELAPSED_S" > "$RUN_DIR/time.txt"

# Primary report paths; fall back to a search in case ECC's layout differs.
RPT="$BUILD/$WS/Synthesis_yosys/report/post_synthesis/qor_summary.rpt"
FEAT="$BUILD/$WS/Synthesis_yosys/feature/post_synthesis/timing_paths.json"
if [ ! -f "$RPT" ]; then
  RPT=$(find "$BUILD/$WS" -name qor_summary.rpt 2>/dev/null | head -1 || true)
fi
if [ ! -f "$FEAT" ]; then
  FEAT=$(find "$BUILD/$WS" -name timing_paths.json 2>/dev/null | head -1 || true)
fi
if [ -z "${RPT:-}" ] || [ ! -f "$RPT" ]; then
  echo "[sta-fast] ERROR: qor_summary.rpt not found under $BUILD/$WS. Last log lines:"
  tail -60 "$RUN_DIR/run.log" || true
  exit 1
fi

python3 "$NPC_DIR/scripts/sta_summary.py" \
  --report "$RPT" \
  --json "${FEAT:-}" \
  --out "$RUN_DIR/manifest.json" \
  --run-id "$RUN_ID" \
  --freq "$FREQ" \
  --strategy "$STRATEGY" \
  --workspace "$WS" \
  --workspace-path "$BUILD/$WS" \
  --vsrc-dir "$NPC_DIR/vsrc" \
  --repo-dir "$REPO_DIR" \
  --time-file "$RUN_DIR/time.txt" \
  2>&1 | tee "$RUN_DIR/summary.txt"

# Keep the most recent 10 run directories.
find "$NPC_DIR/build/sta_fast" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr | awk 'NR>10 {print $2}' | xargs -r rm -rf
