#!/usr/bin/env bash
# Sweep CAGRA build parameters without restarting the server or reloading data.
#
# The bridge re-reads SEEKDB_CUVS_PARAM_FILE on every build, so this harness
# starts one observer, loads the base table once, then for each config drops the
# vector index, recreates it (timed, same statement as the contest) and runs the
# fixed query workload.
set -Eeuo pipefail

OBSERVER=""; BRIDGE=""; DATA_DIR=""; DIM=128; N=250000; NQ=4096; PORT=2881
OUT=summary.jsonl; CONFIGS=""; MEMORY_BUDGET=16G; PUSH=0
GH_USER=${GH_USER:-cccxy123}; GH_TOKEN=${GH_TOKEN:-}
FORK=${FORK:-$GH_USER/seekdb-amd-contest}; RESULTS_BRANCH=${RESULTS_BRANCH:-agent-results}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --observer) OBSERVER=$2; shift 2;;
    --bridge) BRIDGE=$2; shift 2;;
    --data-dir) DATA_DIR=$2; shift 2;;
    --dim) DIM=$2; shift 2;;
    --n) N=$2; shift 2;;
    --nq) NQ=$2; shift 2;;
    --port) PORT=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --configs) CONFIGS=$2; shift 2;;
    --push) PUSH=1; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done

[[ -x "$OBSERVER" && -f "$BRIDGE" && -d "$DATA_DIR" && -n "$CONFIGS" ]] || {
  echo "missing --observer/--bridge/--data-dir/--configs" >&2; exit 2; }

WORK=${WORK:-/workspace/cagra_bench}
BRIDGE_DIR=$(cd "$(dirname "$BRIDGE")" && pwd)
PARAM_FILE=$WORK/cuvs_params.txt
RUNDIR=$WORK/inplace-$DIM
rm -rf "$RUNDIR"; mkdir -p "$RUNDIR" "$WORK"

mysql_bench() { mysql --local-infile=1 --connect-timeout=10 --protocol=TCP -h127.0.0.1 -P"$PORT" -uroot -A -N -B "$@"; }
now_ms() { date +%s%3N; }
log() { echo "[ip $(date +%H:%M:%S)] $*" >&2; }

push_results() {
  [[ "$PUSH" == "1" && -n "$GH_TOKEN" ]] || return 0
  local stage=/tmp/pushback_ip; rm -rf "$stage"; mkdir -p "$stage"
  cp "$OUT" "$stage/" 2>/dev/null || true
  ( cd "$stage" && git init -q && git checkout -q -b "$RESULTS_BRANCH" 2>/dev/null
    git add -A && git -c user.name=bench -c user.email=bench@local commit -q -m "inplace $(date -u +%FT%TZ)" \
    && git push -q "https://$GH_USER:$GH_TOKEN@github.com/$FORK.git" "HEAD:refs/heads/$RESULTS_BRANCH" --force ) \
    && log "pushed $(wc -l < "$OUT") records" || log "WARN: push failed"
}

wait_ready() {
  local pid=$1
  for _ in $(seq 1 240); do
    [[ -d "/proc/$pid" ]] || return 1
    mysql_bench -e 'select 1' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

prepare_sql() {
  local dir=$1
  python3 - "$dir" "$N" "$DIM" "$NQ" <<'PY'
import sys, pathlib, struct
d = pathlib.Path(sys.argv[1]); dim = int(sys.argv[3]); nq = int(sys.argv[4])
raw = (d / "query.f32").read_bytes()
for topk in (10, 100):
    with (d / f"q{topk}.sql").open("w") as f:
        for i in range(nq):
            vals = struct.unpack("<%df" % dim, raw[i*dim*4:(i+1)*dim*4])
            f.write("set ob_query_timeout=600000000; select id from bench.items order by l2_distance(v,[%s]) approximate limit %d;\n"
                    % (",".join("%.7f" % v for v in vals), topk))
PY
}
[[ -f "$DATA_DIR/q10.sql" && -f "$DATA_DIR/q100.sql" ]] || prepare_sql "$DATA_DIR"

FIRST=$(python3 - "$DATA_DIR" "$DIM" <<'PY'
import struct, sys, pathlib
d = pathlib.Path(sys.argv[1]); dim = int(sys.argv[2])
raw = (d / "query.f32").read_bytes()[:dim * 4]
print("[" + ",".join("%.7f" % v for v in struct.unpack("<%df" % dim, raw)) + "]")
PY
)

printf '' > "$PARAM_FILE"

# Never share the port with a leftover observer from an earlier run: it would
# silently serve our queries with the wrong table/schema.
pkill -f "seekdb --base-dir" 2>/dev/null || true
for _ in $(seq 1 40); do mysql_bench -e 'select 1' >/dev/null 2>&1 || break; sleep 0.5; done
if mysql_bench -e 'select 1' >/dev/null 2>&1; then
  log "port $PORT is already serving; aborting so we do not measure the wrong server"
  exit 1
fi
ulimit -n 65535 || true
( cd "$RUNDIR" && exec env LD_LIBRARY_PATH="$BRIDGE_DIR:/opt/hipvs/lib:/opt/rocm/lib" \
  SEEKDB_CUVS_PARAM_FILE="$PARAM_FILE" \
  "$OBSERVER" --base-dir="$RUNDIR" --port="$PORT" --nodaemon \
  --parameter _memory_budget="$MEMORY_BUDGET" --parameter datafile_size=20G \
  --parameter datafile_maxsize=40G --parameter log_disk_size=10G \
  --parameter cpu_count=24 --log-level INFO ) >"$RUNDIR/observer.log" 2>&1 &
OPID=$!
cleanup() {
  kill -TERM "$OPID" 2>/dev/null || true
  for _ in $(seq 1 40); do kill -0 "$OPID" 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL "$OPID" 2>/dev/null || true
}
trap cleanup EXIT
wait_ready "$OPID" || { log "observer failed"; tail -30 "$RUNDIR/observer.log" >&2; exit 1; }

mysql_bench -e "create database if not exists bench; use bench;
  alter system set ob_vector_memory_limit_percentage=30;" >/dev/null

IFS=';' read -r -a cfgs <<< "$CONFIGS"
for cfg in "${cfgs[@]}"; do
  [[ -n "$cfg" ]] || continue
  name=${cfg%%:*}; params=${cfg#*:}
  [[ "$params" == "$cfg" ]] && params=""
  printf '%s\n' "${params//,/$'\n'}" > "$PARAM_FILE"
  log "config $name (${params:-defaults})"

  log "reloading table for $name"
  mysql_bench -e "use bench; drop table if exists items;
    create table items(id bigint primary key, v vector($DIM));" >/dev/null
  mysql_bench -e "set ob_query_timeout=600000000; use bench; load data local infile '$DATA_DIR/base.tsv' into table items fields terminated by '\t' lines terminated by '\n' (id,v);" >/dev/null
  cnt=$(mysql_bench -e "select count(*) from bench.items")
  [[ "$cnt" == "$N" ]] || { log "row count mismatch ($cnt)"; exit 1; }

  t0=$(now_ms)
  mysql_bench -e "set ob_query_timeout=600000000; use bench; create vector index idx_items on items(v)
    with (distance=l2, type=hnsw, lib=cuvs, m=16, ef_construction=200, ef_search=64);" >/dev/null
  mysql_bench -e "set ob_query_timeout=600000000; select id from bench.items order by l2_distance(v,$FIRST) approximate limit 10;" >"$RUNDIR/first.ids"
  t1=$(now_ms)
  rows=$(wc -l < "$RUNDIR/first.ids")
  [[ "$rows" -eq 10 ]] || log "WARN: first query returned $rows rows"

  q0=$(now_ms); mysql_bench < "$DATA_DIR/q10.sql"  > "$DATA_DIR/ids10.tsv";  q1=$(now_ms)
  mysql_bench < "$DATA_DIR/q100.sql" > "$DATA_DIR/ids100.tsv"; q2=$(now_ms)

  python3 - "$DATA_DIR" "$name" "$((t1 - t0))" "$((q1 - q0))" "$((q2 - q1))" "$NQ" "$OUT" <<'PY'
import json, sys, numpy as np
d, tag, b, q10, q100, nq, out = sys.argv[1:8]
b, q10, q100, nq = float(b), float(q10), float(q100), int(nq)
def flat(path):
    return [int(x) for l in open(path) if l.strip() for x in l.split()]
gt = np.fromfile(f"{d}/gt100.i32", dtype=np.int32).reshape(-1, 100)
def recall(path, k):
    vals = flat(path); hit = tot = 0
    nq_seen = min(len(vals) // k, len(gt))
    for i in range(nq_seen):
        s = set(vals[i * k:(i + 1) * k]); g = set(int(x) for x in gt[i][:k])
        hit += len(s & g); tot += len(g)
    return hit / tot if tot else 0.0
rec = {"tag": tag, "dim": None, "build_ms": round(b, 1), "build_s": round(b / 1000, 3),
       "qps_top10": round(nq / (q10 / 1000), 1), "qps_top100": round(nq / (q100 / 1000), 1),
       "recall@10": round(recall(f"{d}/ids10.tsv", 10), 5),
       "recall@100": round(recall(f"{d}/ids100.tsv", 100), 5)}
open(out, "a").write(json.dumps(rec) + "\n")
print(json.dumps(rec))
PY
  push_results
done

log "done"
