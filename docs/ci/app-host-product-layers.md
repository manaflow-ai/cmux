# App-host product layers (opt-in format v1)

The legacy aggregate archive and broker contract remain unchanged. The opt-in
layer format is `cmux.app-host-layers`, version `1`; it is not a legacy `.aar`
artifact with a different name.

```sh
python3 scripts/ci/app_host_layered_products.py pack DERIVED_DATA OUTPUT_DIRECTORY --identity identity.json
python3 scripts/ci/app_host_layered_products.py restore OUTPUT_DIRECTORY/app-host-layers.json NEW_DERIVED_DATA --identity expected-identity.json
```

Both output directories must be absent. Pack reads the producer tree without
mutating it. Products must already be self-contained: stage package frameworks
first; absolute links or links escaping `Build/Products` are rejected. Restore
verifies all archives before extraction, assembles in a private sibling directory,
then atomically publishes the new DerivedData directory. Any existing destination
is rejected without modification. A failure can select the legacy aggregate path.

`identity.json` has exactly these keys:

```json
{
  "source_sha": "0123456789abcdef0123456789abcdef01234567",
  "workflow_run_id": "123",
  "workflow_run_attempt": "2",
  "toolchain": {"xcode": "Xcode 26.0", "architecture": "arm64", "developer": "/Applications/Xcode.app/Contents/Developer"}
}
```

Run and attempt are positive decimal strings; source SHA is the full checked-out
commit, which can differ from the pull request head SHA. The transport separately
validates producer repository, workflow/run head, provider artifact IDs and ZIP
digests. Toolchain is a nonempty string map. Restore requires exact identity
equality; it does not infer compatibility from artifact names.

The canonical `app-host-layers.json` contains:

- `schema`, `version`, `profile: "app-host-full"`, and `identity`.
- `required_layers: ["app-cli", "runtime", "tests", "diagnostics"]`.
- `metadata_policy: {"version": 1, "platform_local_xattrs": ["com.apple.provenance"]}`;
  restore accepts only this fixed policy, never manifest-selected exclusions.
- `directories`: shared structural paths with modes and extended-attribute hashes.
- `layers`, in the same order, each with `name`, `archive` (`NAME.aar`), compressed
  `sha256`, compressed `size`, and its exclusive `entries` inventory.
- Each entry has its original `Build/Products/...` path, mode, extended-attribute
  hashes and type. Files add SHA256 and byte size; symlinks add the literal target.

Layer ownership follows actual product boundaries:

| Layer | Products |
| --- | --- |
| `app-cli` | App code, CLI, signatures, extensions and otherwise unclassified files |
| `runtime` | Complete frameworks, package frameworks, resource bundles, app Resources and non-test plugins |
| `tests` | All xctestruns and complete xctest bundles, including embedded tests and the standalone CmuxTerminalCoreTests consumer |
| `diagnostics` | Top-level dSYMs, compiler Swift modules and `.a`/`.o` inputs; modules contained in runtime frameworks remain with those complete frameworks |

No product is deleted, stripped or deduplicated. Unknown files remain in app-cli.
Shared directory records can appear in multiple archives; file and symlink
ownership cannot overlap. Apple Archive preserves extended attributes and ACLs;
assembly verifies content, modes, literal symlink targets and extended-attribute
hashes except the fixed creator-local `com.apple.provenance` attribute. Every
original hash is recorded, including provenance. Darwin assigns that attribute
when a different process creates/writes restored files, so its value is not a
portable product identity. No attribute is removed or rewritten and OS checks
remain active. Quarantine, custom and signature-related attributes still require
equality. See the original [FFRI provenance research](https://github.com/FFRI/ShowProvenanceInfo).
ACLs are carried by Apple Archive but are not independently compared by
this inventory. Signature bytes are preserved; this check does not replace
`codesign` verification or native execution. All symlink chains must remain within the product namespace; archive
entries cannot appear beneath a symlink.

The canonical manifest always declares all four layers. Consumer authorization
is separate and versioned in `scripts/ci/app-host-layer-consumers.json`; a
consumer may materialize only a canonical-order subset from this full manifest.
The assembler still validates the complete manifest's ownership graph, then
requires, verifies and extracts exactly the selected archives. It compares the
selected reconstruction against the same paths, modes, literal links, content
digests and portable xattr policy before exclusive publication.

Every current consumer requires `app-cli + runtime + tests`. Keeping `app-cli`
and `tests` together preserves the host app and its sealed embedded XCTest
products; keeping all of `runtime` preserves complete framework/module groups.
Top-level diagnostics are the only currently unrequested owner. Unknown products
remain in `app-cli`, so selective restore never guesses away a new product.

The outer transport index pins this manifest's bytes and all four provider
artifact IDs/digests after upload. A selective consumer downloads the index plus
only its authorized layer archives. The index and manifest remain complete: a
consumer cannot rewrite ownership or reinterpret the legacy broker name allowlist
because another producer or layer happens to share a digest.

Run the native archive regression suite on macOS:

```sh
python3 tests/test_app_host_layered_products.py
```

These fixtures exercise real Apple Archive roundtrips and failure isolation.
They do not substitute for the exact CI toolchain's app-host runtime tests.
