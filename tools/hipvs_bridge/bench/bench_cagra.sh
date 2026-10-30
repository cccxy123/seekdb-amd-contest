#!/usr/bin/env bash
# Contest-shaped build/query benchmark for the hipVS CAGRA path.
#
# Times exactly what the contest times: CREATE VECTOR INDEX (offline DDL over an
# already-loaded table) through the first APPROXIMATE query, then measures
# nq-query QPS and recall for Top-10 / Top-100.
#
# Usage:
#   bench_cagra.sh --data-dir DIR --dim 128 --n 250000 --nq 4096 \
#                  [--observer BIN] [--bridge SO] [--port 2881] [--runs 1] \
#                  [--out results.jsonl] [--tag name:ENV=VAL,ENV=VAL ...]
#
# Each --tag run restarts the observer with a fresh store dir and that env.
set -Eeuo pipefail

DATA_DIR=""
DIM=128
N=250000
NQ=4096
OBSERVER=${SEEKDB_HOME:-/seekdb_workspace}/bin/seekdb
BRIDGE=${SEEKDB_HOME:-/seekdb_workspace}/bridge/libseekdb_cuvs_bridge.so
PORT=2881
RUNS=1
OUT=results.jsonl
MEMORY_BUDGET=16G
TAGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir) DATA_DIR=$2; shift 2;;
    --dim) DIM=$2; shift 2;;
    --n) N=$2; shift 2;;
    --nq) NQ=$2; shift 2;;
    --observer) OBSERVER=$2; shift 2;;
    --bridge) BRIDGE=$2; shift 2;;
    --port) PORT=$2; shift 2;;
    --runs) RUNS=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --memory-budget) MEMORY_BUDGET=$2; shift 2;;
    --tag) TAGS+=("$2"); shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done

[[ -n "$DATA_DIR" && -d "$DATA_DIR" ]] || { echo "--data-dir required" >&2; exit 2; }
[[ -x "$OBSERVER" ]] || { echo "observer not executable: $OBSERVER" >&2; exit 2; }
[[ -f "$BRIDGE" ]] || { echo "bridge not found: $BRIDGE" >&2; exit 2; }
(( ${#TAGS[@]} > 0 )) || TAGS=("baseline:")

WORK=${WORK:-/tmp/cagra_bench}
mkdir -p "$WORK"
BRIDGE_DIR=$(cd "$(dirname "$BRIDGE")" && pwd)

mysql_bench() {
  mysql --local-infile=1 --connect-timeout=10 --protocol=TCP -h127.0.0.1 -P"$PORT" -uroot -A -N -B "$@"
}

now_ms() { date +%s%3N; }

wait_ready() {
  local pid=$1
  for _ in $(seq 1 240); do
    [[ -d "/proc/$pid" ]] || return 1
    if mysql_bench -e 'select 1' >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  return 1
}

prepare_sql() {
  local dir=$1
  python3 - "$dir" "$N" "$DIM" "$NQ" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1]); n, dim, nq = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
raw = (d / "query.f32").read_bytes()
q = [raw[i*dim*4:(i+1)*dim*4] for i in range(nq)]
import struct
for topk in (10, 100):
    with (d / f"q{topk}.sql").open("w") as f:
        for i in range(nq):
            vals = struct.unpack("<%df" % dim, q[i])
            f.write("select id from bench.items order by l2_distance(v,[%s]) approximate limit %d;\n"
                    % (",".join("%.7f" % v for v in vals), topk))
first = struct.unpack("<%df" % dim, q[0])
(d / "first_query.txt").write_text("[" + ",".join("%.7f" % v for v in first) + "]")
PY
}

recall_report() {
  local dir=$1 tag=$2 build_ms=$3 q10_ms=$4 q100_ms=$5 run_idx=$6
  python3 - "$dir" "$tag" "$build_ms" "$q10_ms" "$q100_ms" "$NQ" "$run_idx" "$OUT" <<'PY'
import json, sys, numpy as np
d, tag, build_ms, q10_ms, q100_ms, nq, run_idx, out = sys.argv[1:9]
nq = int(nq); build_ms = float(build_ms); q10_ms = float(q10_ms); q100_ms = float(q100_ms)
def read_ids(path):
    rows = []
    for line in open(path):
        line = line.strip()
        rows.append([int(x) for x in line.split()] if line else [])
    return rows
def recall(ids_path, gt_path, k):
    ids = read_ids(ids_path)
    gt = np.fromfile(gt_path, dtype=np.int32).reshape(-1, 100)[:, :k]
    hit = 0; total = 0
    for i, row in enumerate(ids[:len(gt)]):
        s = set(row[:k]); g = set(int(x) for x in gt[i])
        hit += len(s & g); total += len(g)
    return hit / total if total else 0.0
r10 = recall(f"{d}/ids10.tsv", f"{d}/gt10.i32", 10)
r100 = recall(f"{d}/ids100.tsv", f"{d}/gt100.i32", 100)
rec = {
    "tag": tag, "run": int(run_idx),
    "build_ms": round(build_ms, 1),
    "build_s": round(build_ms / 1000.0, 3),
    "qps_top10": round(nq / (q10_ms / 1000.0), 1),
    "qps_top100": round(nq / (q100_ms / 1000.0), 1),
    "q_ms_top10": round(q10_ms, 1),
    "q_ms_top100": round(q100_ms, 1),
    "recall@10": round(r10, 5), "recall@100": round(r100, 5),
}
with open(out, "a") as f:
    f.write(json.dumps(rec) + "\n")
print(json.dumps(rec))
PY
}

prepare_sql "$DATA_DIR"

for spec in "${TAGS[@]}"; do
  tag=${spec%%:*}
  envs=${spec#*:}
  [[ "$envs" == "$spec" ]] && envs=""
  for run in $(seq 1 "$RUNS"); do
    RUNDIR="$WORK/$tag-$run"
    rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"
    echo "== $tag run $run (env: ${envs:-none}) ==" >&2

    env_args=()
    IFS=',' read -r -a kv <<< "$envs"
    for pair in "${kv[@]}"; do
      [[ -n "$pair" ]] && env_args+=("$pair")
    done

    ulimit -n 65535 || true
    ( cd "$RUNDIR" && exec env LD_LIBRARY_PATH="$BRIDGE_DIR:/opt/hipvs/lib:/opt/rocm/lib" "${env_args[@]}" \
      "$OBSERVER" --base-dir="$RUNDIR" --port="$PORT" --nodaemon \
      --parameter _memory_budget="$MEMORY_BUDGET" \
      --parameter datafile_size=20G \
      --parameter datafile_maxsize=40G \
      --parameter log_disk_size=10G \
      --parameter cpu_count=24 \
      --log-level INFO ) >"$RUNDIR/observer.log" 2>&1 &
    OPID=$!
    wait_ready "$OPID" || { echo "observer failed: $tag" >&2; tail -50 "$RUNDIR/observer.log" >&2; exit 1; }

    mysql_bench -e "create database if not exists bench; use bench;
      alter system set ob_vector_memory_limit_percentage=30;
      drop table if exists items;
      create table items(id bigint primary key, v vector($DIM));" >/dev/null
    mysql_bench -e "use bench;
      load data local infile '$DATA_DIR/base.tsv' into table items
      fields terminated by '\t' lines terminated by '\n' (id,v);" >/dev/null
    cnt=$(mysql_bench -e "select count(*) from bench.items")
    [[ "$cnt" == "$N" ]] || { echo "loaded $cnt rows, expected $N" >&2; exit 1; }

    FIRST=$(cat "$DATA_DIR/first_query.txt")
    t0=$(now_ms)
    mysql_bench -e "create vector index idx_items on bench.items(v)
      with (distance=l2, type=hnsw, lib=cuvs, m=16, ef_construction=200, ef_search=64);" >/dev/null
    mysql_bench -e "select id from bench.items order by l2_distance(v,$FIRST) approximate limit 10;" >"$RUNDIR/first.ids"
    t1=$(now_ms)
    [[ $(wc -l < "$RUNDIR/first.ids") -eq 10 ]] || { echo "first query returned $(wc -l < "$RUNDIR/first.ids") rows" >&2; }

    q0=$(now_ms)
    mysql_bench < "$DATA_DIR/q10.sql" > "$DATA_DIR/ids10.tsv"
    q1=$(now_ms)
    mysql_bench < "$DATA_DIR/q100.sql" > "$DATA_DIR/ids100.tsv"
    q2=$(now_ms)

    recall_report "$DATA_DIR" "$tag" "$((t1 - t0))" "$((q1 - q0))" "$((q2 - q1))" "$run"
    grep -a '\[seekdb_cuvs\]\[t\]' "$RUNDIR/observer.log" | tail -20 >&2 || true

    kill -TERM "$OPID" 2>/dev/null || true
    wait "$OPID" 2>/dev/null || true
  done
done
