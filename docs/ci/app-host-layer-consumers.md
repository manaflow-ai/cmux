# App-host compiled-product consumers

Consumer selection is an authorization policy over the canonical
`cmux.app-host-layers` version 1 product. It does not create new archives or
change layer ownership.

The source of truth is `scripts/ci/app-host-layer-consumers.json`, schema
`cmux.app-host-layer-consumers` version 1. Every workflow consumer identity must
appear there before it can use selective restore. The restore client rejects
unknown identities and layer names.

## Current read inventory

| Consumer | Compiled product reads | Required canonical layers |
| --- | --- | --- |
| `app-host-unit-tests-shard-1` | Broad `cmux-unit` xctestrun; host app and embedded test bundle; global-search focused XCTest gate | `app-cli`, `runtime`, `tests` |
| `app-host-unit-tests-shard-2` | Broad `cmux-unit` xctestrun and host app | `app-cli`, `runtime`, `tests` |
| `app-host-unit-tests-shard-3` | Broad `cmux-unit` xctestrun and host app | `app-cli`, `runtime`, `tests` |
| `app-host-unit-tests-shard-4` | Broad `cmux-unit` xctestrun; host app; compiled `cmux` CLI for focused CLI regressions | `app-cli`, `runtime`, `tests` |
| `app-host-unit-tests-shard-5` | Broad `cmux-unit` xctestrun; host app; focused regression-B XCTest gates; compiled `cmux` CLI for terminal-creation coverage | `app-cli`, `runtime`, `tests` |
| `app-host-unit-tests-shard-6` | Broad `cmux-unit` xctestrun; host app; focused XCTest gates and bundled-command coverage | `app-cli`, `runtime`, `tests` |
| `tests-build-and-lag` | `cmux` UI xctestrun, host app executable/resources, display regressions and runtime lag checks | `app-cli`, `runtime`, `tests` |

The shard-6 Ghostty split-theme check builds its own CmuxTerminalCore product.
It does not add a compiled-product requirement; the same worker still runs the
broad app-host suite and therefore keeps the three-layer closure above.

No current consumer reads the canonical `diagnostics` products: top-level
dSYMs, compiler Swift modules, or top-level `.a`/`.o` inputs. Swift modules
inside a runtime framework stay in `runtime`, so omitting `diagnostics` cannot
split a framework/module group. XCTest bundles and xctestruns stay complete in
`tests`. Unknown products continue to belong to `app-cli`.

## Restore and fallback

The transport always verifies the full producer index and canonical manifest.
For a known consumer it fetches only the mapped layer artifacts, verifies their
provider ZIP and inner archive identities, and asks the canonical assembler to
materialize that subset. Publication remains transactional.

A missing or corrupt required layer produces a layered miss. The consumer then
tries the existing aggregate R2 route and, if needed, the verified GitHub
aggregate route. A defect in an unselected layer artifact cannot block a
consumer that never requests it; ownership metadata for that layer still has to
be valid in the complete manifest and index.

The aggregate routes restore all four canonical owners and retain the same
semantic product validation. R2 remains an aggregate transport and does not
interpret this consumer policy.

## Receipts

Each consumer emits `CMUX_APP_HOST_CONSUMER_RECEIPT` with:

- `layers_requested` and `layers_restored`;
- `bytes_requested` and `bytes_transferred` across attempted routes;
- `transfer_duration_seconds`;
- `assembly_duration_seconds`, `restore_duration_seconds`, and their combined
  `restore_assembly_duration_seconds`;
- `fallback_reason` and final `route`;
- `overall_runner_time_seconds`.

The final field spans from the consumer job's first clock step through its final
receipt, so hosted comparisons can include test/runtime work instead of treating
archive size as a proxy for runner savings.
