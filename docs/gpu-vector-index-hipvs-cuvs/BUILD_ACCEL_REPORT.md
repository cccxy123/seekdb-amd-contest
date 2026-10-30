# CAGRA build acceleration report (AMD hipVS contest)

## What is timed

Exactly the contest definition: from

```sql
CREATE VECTOR INDEX idx_items ON items(v)
  WITH (distance=l2, type=hnsw, lib=cuvs, m=16, ef_construction=200, ef_search=64);
```

over an already-loaded table, through the first `APPROXIMATE` query returning
valid rows. Data loading, observer start-up and compilation are excluded.

## Where the baseline spends its time

The V5 bridge builds CAGRA with `graph_degree=128`,
`intermediate_graph_degree=256`, `nn_descent_niter=100`
(`tools/hipvs_bridge/seekdb_cuvs_bridge.c`), i.e. 2x the graph degree and 5x
the iteration budget of the cuVS defaults (64 / 128 / 20).

Sweeping the iteration budget on the 250K x 128 workload gives

```
build(niter) = 11.1 s + niter * 0.348 s
```

so ~11 s of the baseline build is independent of NN-descent (table scan, buffer
fill, host->device copy, graph serialisation, snapshot write, first query) and
every descent iteration costs ~0.35 s. Only the descent part is pure GPU search
work, so that is where the tuning applies.

## Candidate configuration

The bridge picks the graph shape by dimension and always cuts the iteration
budget:

| dimension | graph_degree | intermediate | nn_descent_niter |
| --- | ---: | ---: | ---: |
| <= 128 (SIFT250K) | 96 | 192 | 30 |
| > 128 (Hidden250K) | 128 | 256 | 30 |

The 128d path also shrinks the graph because measurements show no recall change
there. The 256d path keeps the baseline graph degrees: the 256d baseline recall
(0.985 / 0.914) sits close to the gate, and the baseline commit that fixed 256d
recall raised both the graph degrees and the search parameters
(`itopk=max(4*topk,512)`, `search_width=4`), so the graph shape is left alone
there and only the over-provisioned iteration budget is cut.

Search parameters are unchanged from the baseline.

## Measurements

250K x 128, 4096 single-row `APPROXIMATE` queries, one observer, one table load
per configuration (identical DDL and SQL shape to the contest):

| configuration | build | speedup | QPS Top-10 | QPS Top-100 | Recall@10 | Recall@100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 128/256/100 (frozen baseline) | 46.86 s | 1.00x | 151.8 | 146.6 | 1.00000 | 0.99998 |
| 128/256/50 | 28.41 s | 1.65x | 149.3 | 143.2 | 1.00000 | 0.99998 |
| 128/256/30 | 20.61 s | 2.27x | 144.3 | 138.6 | 1.00000 | 0.99998 |
| 96/192/30 | 16.15 s | **2.90x** | 149.2 | 145.5 | 1.00000 | 0.99998 |
| 64/128/30 | 14.26 s | 3.29x | 136.0 | 132.7 | 1.00000 | 0.99997 |

Recall and query throughput are unaffected by the build-side change. The
64/128 variant is faster but was rejected: its query throughput lands on the
90% regression gate.

## Measurement harness

```bash
python3 tools/hipvs_bridge/bench/gen_data.py <dir> <n> <dim> <nq>
bash    tools/hipvs_bridge/bench/bench_inplace.sh \
        --observer <seekdb> --bridge <libseekdb_cuvs_bridge.so> \
        --data-dir <dir> --dim <dim> --n <n> --nq <nq> --push \
        --configs "base:<...>;tuned:<...>"
```

`bench_inplace.sh` starts one observer, then for every configuration recreates
the table, reloads the base vectors, times the DDL plus the first query and runs
`nq` single-row queries for Top-10 and Top-100, reporting QPS and recall against
exact ground truth. `cloud_build.sh` reproduces the evaluator's build commands
and `cloud_sweep3.sh` drives build + sweep on a fresh container.

## Reproducing the build

```bash
HIPVS_ROOT=/opt/hipvs ROCM_ROOT=/opt/rocm \
  tools/hipvs_bridge/build.sh <out>/libseekdb_cuvs_bridge.so
cmake -S . -B build_release -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DOB_ENABLE_UNITY=ON -DOB_USE_LLD=ON \
  -DOB_BUILD_CUVS=ON -DOB_BUILD_CUVS_TRACE=OFF \
  -DCUVS_BRIDGE_LIB=<out>/libseekdb_cuvs_bridge.so
cmake --build build_release --target seekdb
```
