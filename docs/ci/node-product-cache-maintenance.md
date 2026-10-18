# Node-local product cache maintenance

`scripts/ci/node_product_cache.py` keeps immutable compiled-product archives on
owned Glaeda runners. The `seed` and `finalize` workflow hooks keep their
24 GiB logical cache budget on ordinary runners. Confirmed owned runners also
apply a 100 GiB free-space target when their current free space is below that
target; this only lowers node-product-cache retention and never touches source
checkouts or unrelated caches.

For an owned runner, use the explicit maintenance command against the existing
store:

```sh
python3 scripts/ci/node_product_cache.py reclaim --plan --need 100GiB
python3 scripts/ci/node_product_cache.py reclaim --apply --need 100GiB
```

`--plan` is the default and is read-only: it does not create a missing store or
lock files, expire lease files, update statistics, or remove abandoned staging.
`--apply` uses the same per-object nonblocking locks and deadline leases as the
workflow hooks. A live lease, a contended lock, or the optional
`--protect-key` is preserved. `--budget 8GiB` can be used instead of `--need` to
set a direct logical cache limit. The `--need` form derives a conservative
logical budget from current free space and the requested free-space target; it
does not delete source checkouts or other caches.

An owner can override the target with
`CMUX_NODE_PRODUCT_CACHE_RECLAIM_NEED_BYTES` (for example `120GiB`). The hook
only lowers its normal budget when the current free-space measurement requires
it; the variable is ignored when malformed or unset. Non-owned runners do not
apply an implicit target.

The command opens only a fully initialized cache layout. Missing mounts,
symlinked roots or required directories fail closed and leave the filesystem
unchanged. Malformed object entries are skipped; other eligible cache data may
still be reclaimed. Unknown top-level files are preserved for forensic receipts
and future schema versions. Strict maintenance reports abandoned staging as
pending rather than claiming those bytes were reclaimed.
