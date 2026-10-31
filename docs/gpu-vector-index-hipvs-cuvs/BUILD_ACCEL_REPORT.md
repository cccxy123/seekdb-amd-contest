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

| dimension | build algorithm | graph_degree | intermediate | nn_descent_niter |
| --- | --- | ---: | ---: | ---: |
| <= 128 | NN-descent | 96 | 128 | 20 |
| > 128 | IVF-PQ | 128 | 192 | n/a |

The 256d workload is different: it sits on the recall cliff, so the graph shape
stays at the baseline's final degree 128 with the intermediate 192 that an
official run already validated. What changes is how the candidate graph is
built. IVF-PQ builds the same candidate graph several times faster than
NN-descent - 10.34 s against 40.30 s on the contest workload, with identical
recall - and it does not spend time on the 100 refinement iterations that made
previous NN-descent tuning invisible on the scoring machine.

Search parameters are unchanged from the baseline.

## Measurements

250K x 128, 4096 single-row `APPROXIMATE` queries, one observer, one table load
per configuration (identical DDL and SQL shape to the contest):

| configuration | build | speedup | QPS Top-10 | QPS Top-100 | Recall@10 | Recall@100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 128/256/100 (frozen baseline) | 46.86 s | 1.00x | 151.8 | 146.6 | 1.00000 | 0.99998 |
| 128/256/50 | 28.41 s | 1.65x | 149.3 | 143.2 | 1.00000 | 0.99998 |
| 128/256/30 | 20.61 s | 2.27x | 144.3 | 138.6 | 1.00000 | 0.99998 |
| 96/192/30 | 16.15 s | 2.90x | 149.2 | 145.5 | 1.00000 | 0.99998 |
| 96/192/20 | 14.08 s | **3.33x** | 142.5 | 138.6 | 1.00000 | 0.99998 |
| 128/256/20 | 16.90 s | 2.77x | 132.1 | 129.9 | 1.00000 | 0.99998 |
| 128/256/5 (floor) | 8.07 s | 5.81x | 137.5 | 134.3 | 1.00000 | 0.99991 |
| 64/128/30 | 14.26 s | 3.29x | 136.0 | 132.7 | 1.00000 | 0.99997 |
| 96/128/20 | 13.05 s | 3.59x | 142.9 | 141.7 | 1.00000 | 0.99998 |

250K x 256, same protocol:

| configuration | build | speedup | QPS Top-10 | QPS Top-100 | Recall@10 | Recall@100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 128/256/100 (frozen baseline) | 48.54 s | 1.00x | 144.1 | 140.0 | 0.99995 | 0.99998 |
| 128/256/30 | 23.63 s | 2.05x | 135.7 | 132.6 | 0.99993 | 0.99997 |
| 128/256/20 | 19.42 s | 2.50x | 126.8 | 123.1 | 0.99995 | 0.99998 |
| 96/192/20 | 16.49 s | 2.94x | 132.2 | 129.2 | 0.99993 | 0.99998 |
| 128/256/5 (floor) | 13.94 s | 3.48x | 122.9 | 119.6 | 0.99993 | 0.99989 |
| 128/192/25 | 18.43 s | 2.58x | 139.1 | 133.8 | 0.99995 | 0.99997 |
| 96/128/20 | 13.60 s | 3.49x | 141.5 | 138.3 | 0.99993 | 0.99998 |
| 96/128/1 (floor) | 13.92 s | 3.42x | 122.7 | 120.6 | 0.94768 | 0.94622 |
| 128/192/100 IVF-PQ | 10.34 s | 4.59x | 130.2 | 126.3 | 0.99995 | 0.99997 |

Recall is unaffected by the build-side change on either dataset. The `niter=5`
runs bound the fixed cost of the path (table scan, buffer fill, transfer, graph
serialisation, snapshot write, first query): about 6 s at 128d and 12 s at 256d,
with each descent iteration costing ~0.41 s / ~0.36 s respectively.

Query throughput does depend on how well the graph is refined: an interleaved
A/B on the 256d workload (baseline measured before and after each candidate)
gives 92.1% of baseline QPS at 20 iterations, 95.1% at 25 and 96.9% at 30, so
the 256d path uses 25 to keep a safety margin over the 90% regression gate.

The 256d configuration keeps the baseline graph degrees: the 256d baseline sits
close to the recall gate, the baseline commit that fixed 256d recall raised both
the graph degrees and the search parameters, and there is no public 256d
workload to validate a smaller graph against. The 64/128 variant at 128d was
rejected because its query throughput lands on the 90% regression gate.

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

## Query-side tuning

Per-query profiling on the contest workload shows the GPU search itself is ~78%
of a single-row query's wall time (5.39 ms of 6.9 ms), and that no CAGRA search
knob other than the internal top-k queue moves it: `max_iterations`,
`hash_mode`, `search_algo` and `thread_block_size` all landed inside run-to-run
noise. The queue is the knob that matters, because the search is memory-latency
bound on the graph.

The baseline keeps `itopk = max(4*topk, 512)` - 51x k for Top-10. Dropping to
`max(2*topk, 256)` leaves a wide margin over k and measured:

| itopk (Top-10 / Top-100) | 128d QPS | 256d QPS | recall |
| --- | ---: | ---: | --- |
| 512 / 512 (baseline) | 140.1 / 132.4 | 130.2 / 126.3 | 1.000 / 0.9999 |
| 256 / 400 | 177.4 / 147.9 | 171.2 / 141.8 | 1.000 / 0.9999 |
| 256 / 256 (shipped) | 180.0 / 170.8 | 172.0 / 163.0 | 1.000 / 0.9999 |

Per-query device buffers are also reused across searches instead of being
allocated and freed three times per query (worth ~3% throughput).
