# Still-frame codec study

`scripts/measure/codec-study.sh` measures still-image codecs on cmux screens, for three paths:
screenshots computer use sends a model, our own transport and storage (stream idle refresh, history,
thumbnails), and what a person sees in a viewer. Per codec and setting it reports:

- encode ms and decode ms, the median of `runs=` runs after one warm-up run (at most 3 runs when
  the warm-up takes over a second), from pixels in memory to bytes and back;
- the ImageIO decode ms of every encoded file (what WebKit and iOS pay to show it);
- bytes, and bytes against PNG (zlib 6) of the same image;
- text legibility: the Vision OCR character error rate (CER) of the decoded frame against the OCR
  of the lossless original, with the recognizer and normalizing of
  `screen-stream-eval/ocr.swift`, so the two harnesses' numbers compare.

## Run

On an Apple-silicon worker (the scenes are drawn offscreen, so no console grant is needed):

```sh
cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/codec-study.sh \
  --ref SHA --artifact artifacts/codec-study/results.json --key codec-study-SHA8 --timeout 5400
```

Args: `runs=N` (default 5), `only=a,b` (setting ids containing `a` or `b`), `images=N` (the first N
corpus images), `sizes=native,1366`, `ocr=0`. On Linux, or where `swiftc` is absent, it runs the
library codecs on the repo screenshots only: a check of the harness, not numbers to quote.

## Corpus

- `corpus.swift render`: eight cmux-like screens at 1512 x 982 pt, 2x (3024 x 1964 px): a terminal,
  an agent chat, a web page with a photographic hero, and a code editor with a diff pane, each light
  and dark. They are seeded, so every run draws the same pixels.
- `corpus.txt`: committed cmux screenshots, used as they are.
- Each image again at a 1366 px long edge (the size computer use sends a model), scaled with
  CoreGraphics high-quality interpolation; an image already smaller is left out of that set.

## Codecs

| family | how | settings |
|---|---|---|
| PNG | ImageIO; libpng (Pillow) | `imageio-png`, `png-zlib1`, `png-zlib6` |
| JPEG | ImageIO (Apple's encoder); libjpeg-turbo (Pillow); mozjpeg's lossless pass | q75/q85/q92, 4:2:0 and 4:4:4 |
| WebP | libwebp (Pillow) | lossy q80/q90 (always 4:2:0), lossless `cwebp -z` 0, 1, 3, 6 |
| AVIF | libavif with aom, rav1e and SVT-AV1 (pillow-avif-plugin), dav1d decode; ImageIO when it encodes AVIF | fast speeds, q80/q90, 4:4:4 and 4:2:0 (SVT-AV1 is 4:2:0 only) |
| JPEG XL | libjxl (imagecodecs); ImageIO when it encodes JPEG XL | lossless effort 1-3, distance 1.0 effort 1-3 and 7 |
| HEIC | ImageIO (the HEVC encoder) | q75, q85 |

`codec-study-imageio types` lists what this Mac's ImageIO encodes; a setting it cannot encode is
left out. The library versions are pinned in `requirements.txt` (hashes for macOS arm64 and Linux
x86_64); `codec-study.sh` installs them into `.build/codec-study` with a pinned `uv`, and nothing
outside the checkout.

## Output

`artifacts/codec-study/results.json` (`cmux.codec-study/1`: `machine`, `versions`, `rows` per size
and setting, every `records` entry, `errors`), `summary.md`, and the JSON lines each stage wrote.
