#!/usr/bin/env bash
# One-shot end-to-end run for the Radeon Cloud seekdb-hipvs container.
#
#   nohup bash cloud_all.sh > /tmp/cagra_bench/all.out 2>&1 &
#
# 1. push the frozen baseline branch into the team repo (needed for ancestry)
# 2. clone/refresh the contest branch
# 3. build the bridge + seekdb with the exact evaluator flags
# 4. sweep CAGRA build params on 250K x 128 and 250K x 256
# 5. push a results branch back to GitHub so the operator can read it
set -uo pipefail

GH_USER=${GH_USER:-cccxy123}
GH_TOKEN=${GH_TOKEN:?export GH_TOKEN=<pat with repo scope>}
FORK=${FORK:-$GH_USER/seekdb-amd-contest}
TEAM_REPO=${TEAM_REPO:-liuli350/seekdb}
BRANCH=${BRANCH:-competition/amd-cagra}
BASE_BRANCH=${BASE_BRANCH:-amd-oceanbase-official-contest-base-v5}
WORK=${WORK:-/tmp/cagra_bench}
SRC=${SRC:-/tmp/seekdb}
JOBS=${JOBS:-64}
RESULTS_BRANCH=${RESULTS_BRANCH:-agent-results}
SKIP_SWEEP=${SKIP_SWEEP:-0}

mkdir -p "$WORK"
LOG=$WORK/all.log
exec > >(tee -a "$LOG") 2>&1
log() { echo "[all $(date +%H:%M:%S)] $*"; }

push_back() {
  local stage=/tmp/pushback
  rm -rf "$stage"; mkdir -p "$stage"
  cp "$WORK/summary.jsonl" "$stage/" 2>/dev/null || true
  cp "$WORK/build.log" "$stage/" 2>/dev/null || true
  cp "$WORK/all.log" "$stage/" 2>/dev/null || true
  ( cd "$stage" && git init -q && git checkout -q -b "$RESULTS_BRANCH" 2>/dev/null || git checkout -q "$RESULTS_BRANCH"
    git add -A && git -c user.name=bench -c user.email=bench@local commit -q -m "bench results $(date -u +%FT%TZ)" \
    && git push -q "https://$GH_USER:$GH_TOKEN@github.com/$FORK.git" "HEAD:refs/heads/$RESULTS_BRANCH" --force ) \
    && log "results pushed to $FORK#$RESULTS_BRANCH" || log "WARN: results push failed"
}

fail() { log "FATAL: $*"; push_back; exit 1; }

# ---------- 1. baseline history into the team repo ----------
if [[ "${SKIP_TEAM_PUSH:-0}" != "1" ]]; then
  if [[ ! -d /tmp/zbase/.git ]]; then
    log "cloning baseline for team-repo transplant"
    rm -rf /tmp/zbase
    git clone -q --branch "$BASE_BRANCH" https://github.com/zihaomu/seekdb.git /tmp/zbase \
      || log "WARN: baseline clone failed (team push skipped)"
  fi
  if [[ -d /tmp/zbase/.git ]]; then
    log "pushing baseline branch into $TEAM_REPO"
    ( cd /tmp/zbase && git push -q "https://$GH_USER:$GH_TOKEN@github.com/$TEAM_REPO.git" \
        "HEAD:refs/heads/contest/amd-v5-base" ) && log "team repo baseline OK" || log "WARN: team push failed"
  fi
fi

# ---------- 2. contest branch ----------
if [[ -d "$SRC/.git" ]]; then
  log "refreshing $SRC"
  ( cd "$SRC" && git fetch -q --depth 1 origin "$BRANCH" && git reset -q --hard FETCH_HEAD ) || log "WARN: refresh failed, using current tree"
elif [[ -f "$SRC/CMakeLists.txt" ]]; then
  log "using pre-existing source tree at $SRC (no .git)"
else
  log "cloning $BRANCH from $FORK"
  git clone -q --depth 1 -b "$BRANCH" "https://github.com/$FORK.git" "$SRC" || fail "clone failed"
fi

# ---------- 3. toolchain ----------
command -v cargo >/dev/null || log "WARN: cargo missing (seekdb may need Rust)"
command -v hipcc >/dev/null || export PATH=/opt/rocm/bin:$PATH
nproc; free -g | head -2

# ---------- 4. build ----------
log "starting full build (official flags)"
bash "$SRC/tools/hipvs_bridge/bench/cloud_build.sh" --init "$JOBS" || fail "build failed"
OBSERVER=$SRC/build_release/src/observer/seekdb
[[ -x "$OBSERVER" ]] || fail "observer binary missing"
"$OBSERVER" --version 2>&1 | head -2

# ---------- 5. sweep ----------
if [[ "$SKIP_SWEEP" == "1" ]]; then
  log "sweep skipped"
else
  for dim in 128 256; do
    data=$WORK/data-$dim
    if [[ ! -f "$data/gt10.i32" ]]; then
      log "generating 250K x $dim dataset"
      python3 "$SRC/tools/hipvs_bridge/bench/gen_data.py" "$data" 250000 "$dim" 4096 || fail "gen_data $dim"
    fi
  done
  for dim in 128 256; do
    log "sweep dim=$dim"
    bash "$SRC/tools/hipvs_bridge/bench/bench_cagra.sh" \
      --observer "$OBSERVER" \
      --bridge "$WORK/bridge/libseekdb_cuvs_bridge.so" \
      --data-dir "$WORK/data-$dim" --dim "$dim" --n 250000 --nq 4096 --port 2881 \
      --out "$WORK/summary.jsonl" \
      --tag "base-d${dim}:" \
      --tag "n50-d${dim}:SEEKDB_CUVS_NITER=50" \
      --tag "n30-d${dim}:SEEKDB_CUVS_NITER=30" \
      --tag "g96i192n30-d${dim}:SEEKDB_CUVS_GD=96,SEEKDB_CUVS_IGD=192,SEEKDB_CUVS_NITER=30" \
      --tag "g64i128n30-d${dim}:SEEKDB_CUVS_GD=64,SEEKDB_CUVS_IGD=128,SEEKDB_CUVS_NITER=30" \
      || log "WARN: sweep dim=$dim failed"
  done
fi

log "SUMMARY"
cat "$WORK/summary.jsonl" 2>/dev/null
push_back
log "ALL DONE"
