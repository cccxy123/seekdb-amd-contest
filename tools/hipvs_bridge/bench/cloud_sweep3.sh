#!/usr/bin/env bash
# Fresh-instance driver: build once, then sweep build parameters in place.
#
#   GH_TOKEN=... nohup bash cloud_sweep3.sh > /workspace/sweep.out 2>&1 &
set -uo pipefail

SRC=${SRC:-/workspace/seekdb}
WORK=${WORK:-/workspace/cagra_bench}
GH_USER=${GH_USER:-cccxy123}
GH_TOKEN=${GH_TOKEN:?export GH_TOKEN=...}
FORK=${FORK:-$GH_USER/seekdb-amd-contest}
JOBS=${JOBS:-96}
N=${N:-250000}
NQ=${NQ:-4096}

mkdir -p "$WORK"
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

for dim in 128 256; do
  data=$WORK/data-$dim
  if [[ ! -f "$data/gt100.i32" ]]; then
    log "generating $N x $dim"
    python3 "$SRC/tools/hipvs_bridge/bench/gen_data.py" "$data" "$N" "$dim" "$NQ" || exit 3
  fi
done

for dim in 128 256; do
  log "in-place sweep dim=$dim"
  bash "$SRC/tools/hipvs_bridge/bench/bench_inplace.sh" \
    --observer "$OBSERVER" --bridge "$BRIDGE" --data-dir "$WORK/data-$dim" \
    --dim "$dim" --n "$N" --nq "$NQ" --port 2881 --out "$OUT" --push \
    --configs "base-d${dim}:\
n50-d${dim}:SEEKDB_CUVS_NITER=50;\
n30-d${dim}:SEEKDB_CUVS_NITER=30;\
g96i192n30-d${dim}:SEEKDB_CUVS_GD=96,SEEKDB_CUVS_IGD=192,SEEKDB_CUVS_NITER=30;\
g64i128n30-d${dim}:SEEKDB_CUVS_GD=64,SEEKDB_CUVS_IGD=128,SEEKDB_CUVS_NITER=30;\
g64i128n20-d${dim}:SEEKDB_CUVS_GD=64,SEEKDB_CUVS_IGD=128,SEEKDB_CUVS_NITER=20;\
g48i96n20-d${dim}:SEEKDB_CUVS_GD=48,SEEKDB_CUVS_IGD=96,SEEKDB_CUVS_NITER=20;\
g32i64n20-d${dim}:SEEKDB_CUVS_GD=32,SEEKDB_CUVS_IGD=64,SEEKDB_CUVS_NITER=20" \
    || log "WARN: sweep dim=$dim failed"
done

log "SUMMARY"
cat "$OUT" 2>/dev/null
log "DONE"
