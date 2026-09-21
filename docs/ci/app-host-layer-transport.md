# Opt-in app-host layer transport

The default CI artifact remains the aggregate `app-host-products.aar`.
An in-repository pull request with both `full-ci` and `app-host-layers` labels,
or a full-suite manual run selecting `product_artifacts: layered`, enables a
canary. The canary retains the aggregate fallback and also uploads four layers
and one small index artifact. Splitting alone does not reduce bytes: this first
canary deliberately measures the extra packaging and transport work.

The producer first unpacks its freshly packaged aggregate into an owned temporary
directory. Aggregate packaging is the existing owner of build-root symlink
normalization; the layered packer reads that normalized tree without mutating
the original build products. `CMUX_APP_HOST_LAYER_NORMALIZE` reports the extra
normalization elapsed time and outcome. Layer packaging has no default-run cost.

[`app-host-product-layers.md`](app-host-product-layers.md) owns the inner manifest
and local assembly contract. [`app-host-layer-consumers.md`](app-host-layer-consumers.md)
records the current read inventory. The versioned policy in
`scripts/ci/app-host-layer-consumers.json` authorizes every current consumer to
restore `app-cli`, `runtime` and `tests`; `diagnostics` remains declared by the
canonical manifest/index and stays available to future consumers.

## Provider identity and fallback

After four successful uploads, the producer writes `app-host-layer-index.json`.
Its `cmux.app-host-layer-transport` version 1 schema contains:

- The exact repository, producer workflow run and attempt, run head SHA, checkout
  source SHA, and canonical toolchain identity.
- The canonical manifest's filename, SHA-256 and byte size.
- Each layer's exact GitHub artifact ID, provider ZIP digest and byte size, plus
  its canonical inner archive filename, SHA-256 and byte size.

The index and canonical manifest share one artifact. Compile-job outputs pin its
artifact ID and provider ZIP digest. Consumers do not search names or substitute
an origin because content happens to share a digest. Each read checks live
GitHub origin metadata, expiry, current producer attempt, and creation time.
Authenticated `gh api` downloads use repository/artifact-ID endpoints, preserving
the CLI's cross-host redirect handling; the index cannot supply fetch URLs.

The consumer verifies the provider ZIP before opening it, then permits only the
exact expected regular members and independently validates inner bytes. The
index artifact's entire ZIP is capped at 8 MiB, and each JSON file is also capped
at 8 MiB uncompressed. A combined index/manifest ZIP above that cap falls back,
even if each JSON separately satisfies its cap. Each layer is capped at 8 GiB.

Missing, expired, malformed, corrupted or wrong-origin **required** layers leave
the existing aggregate destination untouched and emit `hit=false`. Unselected
layer artifacts are never fetched, while the full index/manifest still validate
their canonical identity and ownership metadata. Local assembly publishes only
to an absent task-owned sibling using the canonical no-replace assembler.
Only a successful verified assembly updates the consumer's DerivedData path.
The ordinary restore step still validates real producer warning-log bytes and
the warning budget, stages package frameworks, and performs product provenance
checks and checkout/toolchain path relocation. A failure in these semantic
checks fails validation; it does not turn into an artifact fallback or bypass.

## Canary receipts

`CMUX_APP_HOST_LAYER_TRANSFER` records each index/layer attempt, including failed
attempts: exact artifact ID, producer run and attempt, layer name, expected ZIP
and inner bytes, received bytes, elapsed seconds and result.
`CMUX_APP_HOST_LAYER_ASSEMBLY` records selected-layer assembly time and outcome.
`CMUX_APP_HOST_CONSUMER_RECEIPT` consolidates the consumer identity, layers
requested/restored, requested/transferred bytes, transfer duration,
restore/assembly duration, fallback reason, final route and overall job runner
time. These are whole operations, not isolated wire throughput measurements.

The existing flat download action and R2 broker keep their aggregate contracts.
A verified selective-layer hit skips both flat transports. A required-layer miss
first tries the flat R2 artifact transport, then GitHub if R2 is unavailable;
all three routes enter the same restore step and retain their inner validation.
R2 does not interpret consumer layer policy; this keeps transport and selection
independent and leaves room for a future R2 layer delivery route that supplies
the same pinned canonical artifacts. Retention stays three days; this change
deletes no artifacts and makes no same-digest origin substitutions. Reusing
individual layers across producers is future work because it must preserve exact
producer identity and the signed product tree contract.

Run the cheap contract checks with:

```sh
python3 tests/test_app_host_layer_transport.py
python3 tests/test_app_host_layer_consumers.py
python3 tests/test_app_host_consumer_receipt.py
python3 tests/test_ci_layered_product_wiring.py
python3 tests/test_ci_product_publication.py
```

On macOS, the transport test includes a real Apple Archive pack/fetch/restore
fixture, and `python3 tests/test_app_host_layered_products.py` verifies the local
assembler. CI runs both before the native compile. Synthetic transport fixtures
do not establish hosted runner performance or full app-host runtime correctness.
