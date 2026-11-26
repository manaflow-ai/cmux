# cmux-shotdiff

The one screenshot comparator and golden store every screenshot gate shares (F1 in cmuxterm-hq
`docs/findings/2026-11-25-linux-everything-map.md`): iOS screenshots on Linux, the macOS app verified on
Linux against Mac goldens, cmux-fp on Linux and Windows, and the web view gallery. One Rust binary on every
runner, so a golden blessed on a Mac judges a Linux render with the same numbers.

## What it judges

- **Per-pixel:** a pixel changed when any RGBA channel moves by more than `channel_tolerance` (16).
  `changed_ratio` = changed / compared pixels; pass at or under `max_changed_ratio` (0.01). These defaults
  are `scripts/ci/ios_gate_screen_diff.py`'s, so a gate that moves here keeps its outcomes.
- **Perceptual:** mean SSIM of luma over 8x8 windows, stride 4; pass at or over `min_ssim` (0.98). It catches
  a shifted control or glyph run the ratio lets through, and forgives antialiasing the ratio counts.
- **Worst tile:** the lowest mean SSIM of any 32x32 tile, always reported (`worst_tile`); with
  `min_tile_ssim` set (0.9 is a good start) it fails a shortened label or a nudged button that moves far under
  1% of pixels and barely moves the mean. Off by default so gates moving here keep their outcomes; turn it on
  once a gate's captures are deterministic (frozen clock, no animation).
- **Ignore masks:** rectangles nothing is compared in (caret, clock, animation), each with a required `why`.
  SSIM skips any window touching one.
- **Regions:** named rectangles with their own `channel_tolerance`, `max_changed_ratio`, `min_ssim` (a
  strict sidebar, a loose glass backdrop). A region fails the verdict on its own.
- **Scale:** `"scale": 2` lets rects be written in points against a Retina capture.
- Different sizes fail with a `size:` reason and no diff image.

Deterministic to the byte: fixed-order f64 sums, floats rounded to 6 places, PNGs encoded with fixed settings.

## CLI

```sh
cmux-shotdiff compare base.png head.png [--spec spec.json] [--diff diff.png] [--json verdict.json]
cmux-shotdiff hash a.png b.png
cmux-shotdiff bless --store goldens --name ios/home/light shot.png [--spec spec.json]
cmux-shotdiff bless --store goldens --dir shots/            # every shots/<name>.png
cmux-shotdiff check --store goldens --name ios/home/light shot.png --diff d.png
cmux-shotdiff batch --store goldens --heads shots/ --out out/ --summary "$GITHUB_STEP_SUMMARY"
cmux-shotdiff get --store goldens --name ios/home/light out.png
```

Exit 0 pass, 1 fail, 2 error. Build it with `cargo build --release -p cmux-shotdiff` in `cmux-tui/`.

Spec (every field optional):

```json
{
  "channel_tolerance": 16, "max_changed_ratio": 0.01, "min_ssim": 0.98, "min_tile_ssim": 0, "scale": 1,
  "ignore":  [{"x": 1180, "y": 0, "w": 100, "h": 24, "why": "menu bar clock"}],
  "regions": [{"name": "sidebar", "x": 0, "y": 0, "w": 240, "h": 800, "min_ssim": 0.995}]
}
```

Cross-renderer (lavapipe against Metal, CEF against WebKit): `"max_changed_ratio": 1` and judge by SSIM.

## Verdict (`cmux-shotdiff.verdict/v1`)

`pass`, `identical`, `reasons[]`, `base`/`head` `{hash, width, height}`, `changed_pixels`, `compared_pixels`,
`ignored_pixels`, `changed_ratio`, `ssim`, `worst_tile` (`{x, y, w, h, ssim}`), `boxes[]` (changed areas merged on a 16 px grid, at most 64),
`regions[]` (`name, pass, changed_ratio, ssim, reasons`), and the `spec` it was judged by.

The diff image: head dimmed to gray, changed pixels red, ignored areas blue, changed boxes outlined orange.

## Golden store

```text
goldens/goldens.json                 sorted manifest: {"schema": "cmux-shotdiff.goldens/v1",
                                       "default_spec": {...}?, "goldens": {"<name>": {hash, width, height, spec?}}}
goldens/objects/<hash[0..2]>/<hash>.png
```

The hash is SHA-256 of the decoded RGBA pixels and size, so any encoding of the same pixels is one golden,
and objects are stored re-encoded, so one hash is always the same bytes. A Mac renders a surface once and
uploads the object by hash; every Linux run after compares against it (mac-golden-cache). Names are slash
paths of `[A-Za-z0-9._@+-]`. A golden's own `spec` wins over `default_spec`, which wins over the defaults;
re-blessing without `--spec` keeps the golden's spec.

`batch` reports each name as `identical`, `pass`, `fail`, `new` (no golden; fails unless `--allow-new`),
`missing` (no head; fails only with `--require-all`) or `error`, in `out/report.json`
(`cmux-shotdiff.report/v1`) with `out/diff/<name>.png` for every one that is not identical.

## Input keys (mac-golden-cache)

```sh
cmux-shotdiff key --inputs .github/golden-inputs.json --family ios-gate --variant iphone [--rev SHA]
# {"schema":"cmux-shotdiff.key/v1","version":"golden-key/v2","family":"ios-gate","variant":"iphone","key":"f419…","files":16482,"rev":"SHA"}
```

A family in `.github/golden-inputs.json` names every file that can change its screenshots (`**` any folders,
`*`/`?` within a name, `!` excludes, last match wins). The key is SHA-256 over the key version, family,
variant, the family's entry as canonical JSON, and `mode blob path` of each matching file at REV from
`git ls-tree` (no checkout needed, so a sparse or shallow clone works). Same inputs, same key, on any runner.

A Mac files a render as a golden store named by its key; every later run with the same key, Linux included,
restores that store and judges its own render with `batch`, with no Mac. The iOS gate's `seed-goldens` job
saves `golden-ios-gate-<variant>-<key>` to R2 (`scripts/ci/r2-cache.sh`, namespace `goldens`); restores need
no credentials. The first render of a key stays the golden; a later one is checked against it.

Wide on purpose: a file left out lets a stale golden pass, one too many only costs a render.

## CI step

```yaml
- uses: ./.github/actions/shotdiff
  with:
    store: path/to/goldens
    heads: ${{ runner.temp }}/shots
    out: ${{ runner.temp }}/shotdiff
    allow-new: "true"     # the first shadow run only
- uses: actions/upload-artifact@v4
  if: ${{ always() && !cancelled() }}
  with: { name: shotdiff, path: "${{ runner.temp }}/shotdiff" }
```

The action builds the binary from the checkout (pinned toolchain), runs `batch`, appends the table to the step
summary and fails the step on a fail.
