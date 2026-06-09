# Reading Build Settings

How to consume `GetTargetBuildSettings` output during a security audit.

## Schema

`GetTargetBuildSettings` returns:

```json
{ "buildSettings": [ { "macroName": "...", "evaluatedValue": "...", "value": "...", "targetValue": "..." }, ... ] }
```

Field reference:

- **`macroName`** — setting name (always present).
- **`evaluatedValue`** — fully resolved value after `$(...)` macro expansion. This is what the build actually sees. Use this for audit decisions. May be omitted when the resolved value is empty — treat its absence as an empty string.
- **`value`** — raw, unexpanded value as written in the source (often missing).
- **`targetValue`** — present only when the setting is explicitly set at the **target** level (vs. inherited from project level). Use this to detect per-target overrides.

## Handling large results

If `GetTargetBuildSettings` writes its output to a saved file due to a token limit, run `scripts/filter_build_settings.py` against that file to extract only catalog-relevant settings. Do not read the saved file linearly.

## Filter recipes

The script lives at `scripts/filter_build_settings.py` (relative to the skill root). It derives its filter regex from `references/settings-and-entitlements-catalog.md` at runtime, so adding settings to the catalog automatically extends the filter. Override with `--regex` if you need a narrower filter.

### Compact `name=value` view

```sh
python3 scripts/filter_build_settings.py <saved-file>
```

### With explicit target-override flag

```sh
python3 scripts/filter_build_settings.py <saved-file> --show-overrides
```

### Only catalog settings NOT at a hardened value (the "what's left to do" view)

```sh
python3 scripts/filter_build_settings.py <saved-file> --unhardened-only
```

The `--show-overrides` and `--unhardened-only` flags can be combined.
