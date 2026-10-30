#!/usr/bin/env python3
"""Generate a contest-shaped dataset: N x dim float32 base + nq queries + exact GT.

Usage: gen_data.py <out_dir> <n> <dim> <nq> [seed]
Writes base.f32, query.f32, base.tsv, query.tsv, gt10.i32, gt100.i32.
"""
import os
import sys

import numpy as np


def main():
    out = sys.argv[1]
    n = int(sys.argv[2])
    dim = int(sys.argv[3])
    nq = int(sys.argv[4])
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 20261030
    os.makedirs(out, exist_ok=True)

    rng = np.random.default_rng(seed)
    # Clustered base, normalized: closer to real embedding data than pure noise.
    clusters = max(8, int(np.sqrt(n / 64)))
    centers = rng.normal(size=(clusters, dim)).astype(np.float32)
    labels = rng.integers(0, clusters, size=n)
    base = centers[labels] + 0.35 * rng.normal(size=(n, dim)).astype(np.float32)
    base /= np.maximum(np.linalg.norm(base, axis=1, keepdims=True), 1e-9)

    pick = rng.choice(n, size=nq, replace=False)
    queries = base[pick] + 0.05 * rng.normal(size=(nq, dim)).astype(np.float32)
    queries /= np.maximum(np.linalg.norm(queries, axis=1, keepdims=True), 1e-9)

    base.astype(np.float32).tofile(os.path.join(out, "base.f32"))
    queries.astype(np.float32).tofile(os.path.join(out, "query.f32"))

    def dump_tsv(path, data):
        with open(path, "w") as f:
            for i, row in enumerate(data):
                f.write("%d\t[%s]\n" % (i, ",".join("%.6f" % v for v in row)))

    dump_tsv(os.path.join(out, "base.tsv"), base)
    dump_tsv(os.path.join(out, "query.tsv"), queries)

    gt = np.empty((nq, 100), dtype=np.int32)
    base_sq = np.einsum("ij,ij->i", base, base)
    for start in range(0, nq, 64):
        q = queries[start:start + 64]
        d = base_sq[None, :] - 2.0 * (q @ base.T) + np.einsum("ij,ij->i", q, q)[:, None]
        gt[start:start + 64] = np.argsort(d, axis=1)[:, :100]
    gt[:, :10].tofile(os.path.join(out, "gt10.i32"))
    gt.tofile(os.path.join(out, "gt100.i32"))
    print("generated n=%d dim=%d nq=%d clusters=%d -> %s" % (n, dim, nq, clusters, out))


if __name__ == "__main__":
    main()
