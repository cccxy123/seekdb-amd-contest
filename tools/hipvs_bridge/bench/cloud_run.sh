#!/usr/bin/env bash
# One-shot driver for the Radeon Cloud seekdb-hipvs container.
#
#   bash tools/hipvs_bridge/bench/cloud_run.sh probe   # env facts + bridge build + 10K smoke
#   bash tools/hipvs_bridge/bench/cloud_run.sh sweep   # 250K build/recall/qps for a config list
#
# Results land in /tmp/cagra_bench/summary.jsonl and are echoed as one JSON line each.
set -uo pipefail

STAGE=${1:-probe}
SEEKDB_HOME=${SEEKDB_HOME:-/seekdb_workspace}
WORK=/tmp/cagra_bench
BRIDGE_DIR=$WORK/bridge
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
mkdir -p "$WORK" "$BRIDGE_DIR"

log() { echo "[cloud_run] $*" >&2; }

probe_env() {
  log "repo=$REPO_ROOT"
  log "seekdb_home=$SEEKDB_HOME"
  { ls -la "$SEEKDB_HOME" 2>&1 | head -30; } >&2
  { ls -la "$SEEKDB_HOME/bin" "$SEEKDB_HOME/bridge" "$SEEKDB_HOME/scripts" 2>&1 | head -40; } >&2
  { echo "--- start_observer.sh ---"; cat "$SEEKDB_HOME/scripts/start_observer.sh" 2>&1 | head -60; } >&2
  { echo "--- versions ---"; "$SEEKDB_HOME/bin/seekdb" --version 2>&1 | head -3; } >&2
  { ldd "$SEEKDB_HOME/bin/seekdb" 2>&1 | grep -i -E "cuvs|hip|rocm" | head -10; } >&2
  { echo "--- hipvs ---"; ls /opt/hipvs /opt/hipvs/lib 2>&1 | head -20; } >&2
  log "nproc=$(nproc) mem=$(free -g | awk '/Mem:/{print $2}')G"
  log "hipcc=$(command -v hipcc || echo MISSING) cmake=$(command -v cmake || echo MISSING)"
  log "gpu: $(amd-smi static 2>/dev/null | grep -m1 MARKET_NAME || echo unknown)"
  log "python3=$(python3 -c 'import numpy;print(numpy.__version__)' 2>&1)"
}

build_bridge() {
  log "building bridge -> $BRIDGE_DIR/libseekdb_cuvs_bridge.so"
  HIPVS_ROOT=/opt/hipvs ROCM_ROOT=/opt/rocm \
    bash "$REPO_ROOT/tools/hipvs_bridge/build.sh" "$BRIDGE_DIR/libseekdb_cuvs_bridge.so" || return 1
  ldd "$BRIDGE_DIR/libseekdb_cuvs_bridge.so" | grep -E "cuvs|amdhip" | head -5 >&2
}

observer_bin() {
  local built="$REPO_ROOT/build_release/src/observer/seekdb"
  if [[ -x "$built" ]]; then echo "$built"; else echo "$SEEKDB_HOME/bin/seekdb"; fi
}

run_bench() {
  local stage=$1; shift
  bash "$REPO_ROOT/tools/hipvs_bridge/bench/bench_cagra.sh" \
    --observer "$(observer_bin)" \
    --bridge "$BRIDGE_DIR/libseekdb_cuvs_bridge.so" \
    --out "$WORK/summary.jsonl" \
    "$@"
}

case "$STAGE" in
  probe)
    probe_env
    build_bridge || { log "bridge build FAILED"; exit 3; }
    data=$WORK/data-smoke
    [[ -f "$data/gt10.i32" ]] || python3 "$REPO_ROOT/tools/hipvs_bridge/bench/gen_data.py" "$data" 10000 128 512
    run_bench probe --data-dir "$data" --dim 128 --n 10000 --nq 512 --port 2881 \
      --tag "probe:"
    ;;
  sweep)
    probe_env
    build_bridge || { log "bridge build FAILED"; exit 3; }
    for dim in 128 256; do
      data=$WORK/data-$dim
      [[ -f "$data/gt10.i32" ]] || python3 "$REPO_ROOT/tools/hipvs_bridge/bench/gen_data.py" "$data" 250000 "$dim" 4096
    done
    for dim in 128 256; do
      data=$WORK/data-$dim
      run_bench sweep --data-dir "$data" --dim "$dim" --n 250000 --nq 4096 --port 2881 \
        --tag "base-d${dim}:" \
        --tag "n50-d${dim}:SEEKDB_CUVS_NITER=50" \
        --tag "n30-d${dim}:SEEKDB_CUVS_NITER=30" \
        --tag "g96i192n30-d${dim}:SEEKDB_CUVS_GD=96,SEEKDB_CUVS_IGD=192,SEEKDB_CUVS_NITER=30" \
        --tag "g64i128n30-d${dim}:SEEKDB_CUVS_GD=64,SEEKDB_CUVS_IGD=128,SEEKDB_CUVS_NITER=30"
    done
    ;;
  *)
    log "unknown stage $STAGE"; exit 2;;
esac

log "done; summary:"
cat "$WORK/summary.jsonl" 2>/dev/null
