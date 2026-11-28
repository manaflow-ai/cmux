# Patch bundles (RFD 0224 phase 5)

`<channel>/<target>.json` (target as `x86_64-unknown-linux-musl`) names one signed patch bundle for hosts on one build:

```json
{"id": "fix-1", "base": "<full commit of the build>", "days": 14,
 "files": [{"path": "web/app.js", "source": "cmux-tui/patches/feat-cmux-next/fix-1/app.js"}]}
```

A push to feat-cmux-next that touches this directory signs and publishes it
(`.github/workflows/cmux-patch-bundle.yml`, `scripts/ci/cmux-patch-bundle.py`). acpmux's
`host self-update` tick writes the files under `~/.acpmux/patches/<target>/files` and keeps them
only while `acpmux --json daemon status` still answers; the config ring's
`acpmux.self-update.hold` flag holds it. A rolled-back id is never tried again on that host, so a
fix ships under a new id.
