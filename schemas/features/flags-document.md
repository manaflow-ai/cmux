# The signed flags document

`release-notes/next/flags.json` is the remote document for cmux features. The nightly
(`.github/workflows/nightly.yml`, the step that copies it to `notes/flags.json`) signs it with
the `content-signing` key and publishes `notes/flags.json` and `notes/flags.json.sig` next to
the release notes. The design is section 3.9 of
`plans/cmux-next/chrome-parity/p12-perf-process.md`. The model is Chromium's variations seed:
`components/variations/variations_seed_store.cc` keeps only a seed whose signature verifies,
and `components/variations/study_filtering.cc` filters a study by min and max version.

## Version

The document stays `"version": 1`. The nightly asserts this:

```sh
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("version")==1 and isinstance(d.get("default",{}),dict) and isinstance(d.get("cohorts",{}),dict)' release-notes/next/flags.json
```

Add keys. Do not change the version: a different version fails the nightly, and every reader
ignores a document that is not version 1. A reader ignores a key that it does not know, so an
old build reads a new document without error.

## Shape

```json
{
  "version": 1,
  "default": {
    "DisabledFeatures": ["cloud-vm"],
    "Features": { "terminalHolder": "off" },
    "FeaturesSerial": 12
  },
  "cohorts": {
    "nightly-perf": {
      "Features": { "cefLayerHosting": "on" },
      "FeaturesSerial": 12,
      "FeaturesMinBuild": 4200,
      "FeaturesMaxBuild": 4299,
      "FeaturesExpiresAt": 1798761600
    }
  }
}
```

`default` holds the keys for every install. `cohorts` holds the keys for one tester cohort
(`CMUX_TUI_COHORT`, or `tester.cohort` in cmux.json; the default cohort is `default`). A
reader resolves the keys of one cohort like this:

1. Take the keys of `default`.
2. Put each key of the cohort in place of the same key of `default`.
3. `Features` is the exception: its names merge. For a name in both, the cohort's state wins.

## Keys

| Key | Type | Meaning |
| --- | --- | --- |
| `DisabledFeatures` | array of strings | Daemon policy names that are off (the shape of `managed/policy.rs`). Not a feature registry name. |
| `Features` | object, name to `"on"` or `"off"` | The remote override of each registry feature (`features.d/<name>.json`, step 4 of the resolution order). |
| `FeaturesSerial` | integer, 0 or more | The publish number. Each publish sets a higher number. |
| `FeaturesExpiresAt` | integer, Unix seconds | `Features` do not apply at this time or after it. |
| `FeaturesMinBuild` | integer | `Features` do not apply to a build number below this. |
| `FeaturesMaxBuild` | integer | `Features` do not apply to a build number above this. |
| `Studies` | array | Nightly field trials (task p12-perf-process-152). Each study has `feature`, `arms` (`name`, `weight`, `state`), `channel`, `min_build` and `max_build`. This file reserves the key; task 152 defines the arms. |

The build number is `CFBundleVersion` of the app (the nightly sets it to `NIGHTLY_BUILD`).

## Rules for the `Features` keys

A reader applies these rules to the resolved keys of its cohort. When a rule fails, the reader
uses no `Features` from the document. It still uses the other keys, for example
`DisabledFeatures`.

- **Malformed**: a `Features*` key has the wrong type, or a state is not `"on"` or `"off"`.
  The reader rejects all `Features`. It does not apply a part of them.
- **Expired**: the time now is at `FeaturesExpiresAt` or after it.
- **Build out of range**: `FeaturesMinBuild` or `FeaturesMaxBuild` is set, and the build number
  is below the minimum, above the maximum, or not known.
- **Older serial**: a reader that has a cached document refuses a new document that lowers
  `FeaturesSerial` for the default cohort, or for a cohort that both documents name. A document
  with no `FeaturesSerial` has serial 0. This stops a replay of an older, correctly signed
  document from undoing a kill switch.
- **Unknown name**: the daemon keeps only the names of its own features (`process` `daemon` or
  `both`) and ignores the other names. The app rejects a name that the registry does not
  declare and reports it (task p12-perf-process-092).

## Readers

- The daemon: `cmux-tui/crates/cmux-tui/src/feature_flags.rs`. `store` verifies the signature
  and the serial before it caches the document. `features(keys, context)` gives the overrides of
  the daemon's features. The daemon keeps its own reader for `DisabledFeatures`.
- The app: `ContentSignature` (`CmuxNextUpdater/ReleaseNotes/ReleaseNotes.swift`) verifies the
  signature. The remote overrides model (task p12-perf-process-092) applies these rules.

## Test vectors

`flags-vectors.json` holds the shared cases:

- `signature`: the exact document bytes, the exact `.sig` text, and whether the test key
  accepts it. A changed byte, a changed signature bit and a different key fail. The test key
  is the Ed25519 key with a seed of 32 bytes of 7. It is not the `content-signing` key.
- `resolve`: a document, a cohort, a build number and a time, and the `Features` and
  `FeaturesSerial` that result, or the reason for the rejection
  (`malformed`, `expired`, `buildUnknown`, `buildBelowMin`, `buildAboveMax`).

The Rust unit tests in `feature_flags.rs` and the Swift suite `FlagsDocumentVectorTests`
(CmuxNextAppTests) read this file. When you change a rule, change the vectors and every reader
in the same commit.

## Publish

Every publish sets a higher `FeaturesSerial` than the last publish, and keeps `"version": 1`.
The checked-in document has an empty `Features` object and serial 1.
