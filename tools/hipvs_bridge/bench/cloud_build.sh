#!/usr/bin/env bash
# Build seekdb + the hipVS bridge inside the Radeon Cloud container with the
# exact command sequence the contest evaluator uses.
#
#   bash tools/hipvs_bridge/bench/cloud_build.sh [--init] [jobs]
#
# Artifacts: build_release/src/observer/seekdb and /tmp/cagra_bench/bridge/.
# Log:       /tmp/cagra_bench/build.log
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=/tmp/cagra_bench
BRIDGE_DIR=$WORK/bridge
LOG=$WORK/build.log
JOBS=${JOBS:-64}
INIT=0
for arg in "$@"; do
  case "$arg" in
    --init) INIT=1;;
    *) JOBS=$arg;;
  esac
done

mkdir -p "$WORK" "$BRIDGE_DIR"
cd "$REPO_ROOT" || exit 1
log() { echo "[cloud_build] $*" | tee -a "$LOG"; }

if [[ "$INIT" == "1" ]]; then
  log "fetching third-party deps (mirrors.oceanbase.com)"
  bash build.sh init 2>&1 | tee -a "$LOG" || { log "dep init failed"; exit 2; }
fi

log "building bridge"
HIPVS_ROOT=/opt/hipvs ROCM_ROOT=/opt/rocm \
  bash tools/hipvs_bridge/build.sh "$BRIDGE_DIR/libseekdb_cuvs_bridge.so" 2>&1 | tee -a "$LOG" \
  || { log "bridge build failed"; exit 3; }

# The prebuilt image binary resolves the bridge through RPATH, so keep the copy
# under the image path in sync with what we just built.
if [[ -d /seekdb_workspace/bridge ]]; then
  cp "$BRIDGE_DIR/libseekdb_cuvs_bridge.so" /seekdb_workspace/bridge/libseekdb_cuvs_bridge.so
  log "synced bridge into /seekdb_workspace/bridge"
fi

log "configuring seekdb (official flags)"
cmake -S . -B build_release -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DOB_ENABLE_UNITY=ON \
  -DOB_USE_LLD=ON \
  -DOB_BUILD_CUVS=ON \
  -DOB_BUILD_CUVS_TRACE=OFF \
  -DCUVS_BRIDGE_LIB="$BRIDGE_DIR/libseekdb_cuvs_bridge.so" 2>&1 | tee -a "$LOG" \
  || { log "cmake failed"; exit 4; }

log "building seekdb with $JOBS jobs"
cmake --build build_release --target seekdb -j "$JOBS" 2>&1 | tee -a "$LOG" \
  || { log "build failed"; exit 5; }

ls -la build_release/src/observer/seekdb | tee -a "$LOG"
log "done"
