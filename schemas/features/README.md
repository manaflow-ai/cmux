# Features

A feature is a switch that ships in Release: a perf path that rolls out behind a default,
a kill switch a signed remote document can turn off, or a Labs experiment. Each feature is
one file, `features.d/<name>.json`, so parallel changes never touch the same file. The model
is Chromium's `base::Feature` (`base/feature_list.h`), `base::FeatureParam`
(`base/metrics/field_trial_params.h`) and the owner and expiry of each flag
(`chrome/browser/flag-metadata.json`). The full design, with the resolution order, remote
overrides and safe mode, is section 3.9 of `plans/cmux-next/chrome-parity/p12-perf-process.md`.

## Add or change a feature

1. Write `features.d/<name>.json` (fields below). `features.schema.json` is the contract.
2. Run `python3 scripts/cmux-next/gen-features.py`. It validates every file and writes
   - `Packages/macOS/CmuxNext/Sources/CmuxNextFeatures/Features.generated.swift` (every feature),
     once `Packages/macOS/CmuxNext/Package.swift` declares the `CmuxNextFeatures` target (task
     p12-perf-process-091)
   - `cmux-tui/crates/cmux-features/src/generated.rs` (features with process `daemon` or `both`),
     once `cmux-tui/crates/cmux-features/Cargo.toml` exists (task 095)

   Until its target exists, a file is not written or checked, and the script prints
   `skipped <file>`. So `--check` is green before 091 and 095 land, and each of them commits
   its own generated file.
3. Commit the JSON and the generated files together. Never edit a generated file;
   `gen-features.py --check` exits 1 when one differs from the JSON, or when a file is invalid.
   The Rust file goes through rustfmt (the pre-commit hook formats it too), so the Rust check
   ignores layout and compares content.

```json
{
  "name": "cefLayerHosting",
  "owner": "PL-cef-layer",
  "description": "Host Chromium pages in the window's layers.",
  "defaults": { "dev": true, "nightly": true, "release": false },
  "kind": "perfPath",
  "expires": "2026-12-20",
  "process": "app",
  "params": [
    { "name": "syncDeadline", "type": "duration", "default": 0.05, "min": 0, "max": 1,
      "description": "Longest wait for the page's resized frame.", "replaces": "browserResize.syncDeadline" }
  ],
  "stories": ["browse-heavy"],
  "sticky": false,
  "runtimeMutable": false,
  "replaces": ["browserResize.layerHosting"]
}
```

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | lowerCamelCase, equal to the file name. The wire key in `flags.json`, `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES`. |
| `owner` | yes | As written in an Owner cell of `plans/cmux-next/OWNERS.md`, or a `PL-*` workstream named in `plans/cmux-next/perf-lead.md`. The generator checks it. |
| `description` | yes | One sentence: what turning it on changes. No `"`, `\` or control characters. |
| `defaults` | yes | `{dev, nightly, release}` booleans: the channel default, the last step of the resolution order. |
| `kind` | yes | `perfPath`, `killSwitch` or `labs`. |
| `expires` | perfPath | `YYYY-MM-DD`. A perfPath feature expires at most 60 days after the day the generator runs; after that day it warns until the feature is made permanent or removed. |
| `process` | yes | `app`, `daemon`, `both` or `chromium`. With `both`, the daemon keeps its own value for a session when the app's differs. |
| `chromium_feature` | with `chromium` only | The Chromium `base::Feature` name passed to CEF through `--enable-features`/`--disable-features` (disable wins). |
| `params` | yes (may be `[]`) | Typed params (`int`, `double`, `duration` in seconds, `bool`). Numbers are finite and need `min` and `max`, and the default is inside them; `int` values fit in 64 bits. `replaces` names the numeric tunable a param took over. |
| `stories` | yes (may be `[]`) | Lab stories that bench both arms. A perfPath feature needs at least one. Once `scripts/perf-lab/stories.d/` exists, each must have a file there. |
| `sticky` | yes | A remote off stays off in safe mode, even when the remote document is dropped. |
| `runtimeMutable` | yes | The feature can change while the process runs. `true` needs `teardownTest`, a test that exists. Swift: `Target.Suite/testName`, a method of the type or extension `Suite` in `Packages/macOS/**/Tests/<Target>/`, named `test*` (XCTest) or marked `@Test`. Rust: `crate::module::test`, a `#[test]` or `#[tokio::test]` fn directly in that module of the crate (inline `mod` blocks, `module.rs` or `module/mod.rs`; `crate::file::test` for `tests/file.rs`). |
| `replaces` | no | Tunable keys and env switches this feature took over. Each key belongs to one feature. On DEV and NIGHTLY the App reads each replaced Bool tunable from the build's `debug-tunables.json` at launch and gives it to the feature as its local override (step 3; `Feature.replaces`). |

## Generated interface

The generated files only declare data; the core types live in `CmuxNextFeatures` (task
p12-perf-process-091) and `cmux-features` (task 095).

- Swift: `nonisolated extension Feature` with one `public static let <name> = Feature(index:name:owner:description:kind:process:chromiumFeature:defaults:expires:params:stories:sticky:runtimeMutable:)`
  per feature, and `public static let registered: [Feature]`, where `registered[f.index] == f`.
  `defaults` is `FeatureDefaults(dev:nightly:release:)`. A param is
  `FeatureParamSpec(name:description:value:)` with `value` one of `.int(default:min:max:)`,
  `.double(default:min:max:)`, `.duration(default:min:max:)` (seconds) or `.bool(default:)`.
- Rust: one `pub const <SCREAMING_NAME>: crate::Feature` per daemon-side feature and
  `pub static REGISTERED: &[crate::Feature]`. The fields are the Swift ones in snake case
  except `chromiumFeature` (the daemon has no Chromium features), with `expires: Option<&'static str>`, `params: &'static [crate::FeatureParamSpec]` and
  `crate::FeatureParamValue::{Int, Double, Duration, Bool}`.

Indices follow the sorted names and change when a feature is added; names are the only key
that crosses a process or a build.

## Migration queues

These are reports for the migration work, not gates. Both exit 0.

- `gen-features.py --unmigrated` (MQ6): the Bool tunables still declared that no feature's
  `replaces` names, of two kinds: the seed list in the script (`browserResize.layerHosting`,
  `sidebar.*slideHoldsContent` and the rest), and every Bool tunable
  declared in, or read as `Type.name` from, a file that a Performance Lead workstream owns in
  `plans/cmux-next/OWNERS.md`. Also the daemon env switch `CMUX_TUI_TERMINAL_HOST_MODEL`. A seed
  that matches nothing declared or replaced (renamed or removed) prints a warning.
- `gen-features.py --unmigrated-params` (MQ16): numeric tunables declared in, or read as
  `Type.name` from, a file that a Performance Lead workstream owns in
  `plans/cmux-next/OWNERS.md`, and that no param's `replaces` names.

Each prints one `key<TAB>path:line` row per item and a count. Add `--count` to print only the number.
