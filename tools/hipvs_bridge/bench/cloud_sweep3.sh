#!/usr/bin/env bash
# Fresh-instance driver: build once, then sweep build parameters in place.
#
#   GH_TOKEN=... nohup bash cloud_sweep3.sh > /workspace/sweep.out 2>&1 &
#   DIMS=256 CFG_TEMPLATE="base-d%DIM%:;g96i192n30-d%DIM%:SEEKDB_CUVS_GD=96,..." \
#     GH_TOKEN=... bash cloud_sweep3.sh
set -uo pipefail

SRC=${SRC:-/workspace/seekdb}
WORK=${WORK:-/workspace/cagra_bench}
GH_USER=${GH_USER:-cccxy123}
GH_TOKEN=${GH_TOKEN:?export GH_TOKEN=...}
FORK=${FORK:-$GH_USER/seekdb-amd-contest}
JOBS=${JOBS:-96}
N=${N:-250000}
NQ=${NQ:-4096}
DIMS=${DIMS:-"128 256"}
CFG_TEMPLATE=${CFG_TEMPLATE:-"base-d%DIM%:;n50-d%DIM%:SEEKDB_CUVS_NITER=50;n30-d%DIM%:SEEKDB_CUVS_NITER=30;g96i192n30-d%DIM%:SEEKDB_CUVS_GD=96,SEEKDB_CUVS_IGD=192,SEEKDB_CUVS_NITER=30;g64i128n30-d%DIM%:SEEKDB_CUVS_GD=64,SEEKDB_CUVS_IGD=128,SEEKDB_CUVS_NITER=30"}
RESULTS_BRANCH=${RESULTS_BRANCH:-agent-results}

mkdir -p "$WORK"
LOCKFILE=$WORK/.sweep.pid
if [[ -f "$LOCKFILE" ]] && kill -0 "$(cat "$LOCKFILE" 2>/dev/null)" 2>/dev/null; then
  echo "another sweep is already running (pid $(cat "$LOCKFILE")); refusing to start"; exit 1
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT
LOG=$WORK/sweep.log
exec > >(tee -a "$LOG") 2>&1
log() { echo "[s3 $(date +%H:%M:%S)] $*"; }

BRIDGE=$WORK/bridge/libseekdb_cuvs_bridge.so
OBSERVER=$SRC/build_release/src/observer/seekdb
OUT=$WORK/summary.jsonl

if [[ ! -x "$OBSERVER" ]]; then
  log "no observer binary; building"
  bash "$SRC/tools/hipvs_bridge/bench/cloud_build.sh" --init "$JOBS" || { log "build failed"; exit 2; }
fi
"$OBSERVER" --version 2>&1 | head -2

for dim in $DIMS; do
  data=$WORK/data-$dim
  if [[ ! -f "$data/gt100.i32" ]]; then
    log "generating $N x $dim"
    python3 "$SRC/tools/hipvs_bridge/bench/gen_data.py" "$data" "$N" "$dim" "$NQ" || exit 3
  fi
done

# Export the accumulated records once so a later instance can append to them.
if [[ ! -f "$OUT" ]]; then
  curl -sL -m 60 -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$FORK/contents/summary.jsonl?ref=$RESULTS_BRANCH" \
    -H "Accept: application/vnd.github.raw" -o "$OUT" 2>/dev/null || true
  log "seeded results from $RESULTS_BRANCH ($(wc -l < "$OUT" 2>/dev/null || echo 0) records)"
fi

for dim in $DIMS; do
  CFGS=${CFG_TEMPLATE//%DIM%/$dim}
  log "in-place sweep dim=$dim"
  bash "$SRC/tools/hipvs_bridge/bench/bench_inplace.sh" \
    --observer "$OBSERVER" --bridge "$BRIDGE" --data-dir "$WORK/data-$dim" \
    --dim "$dim" --n "$N" --nq "$NQ" --port 2881 --out "$OUT" --push \
    --configs "$CFGS" \
    || log "WARN: sweep dim=$dim failed"
done

log "SUMMARY"
cat "$OUT" 2>/dev/null
log "DONE"
