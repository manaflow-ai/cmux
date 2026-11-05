# Screen stream eval

One harness that runs every screen stream we ship, and later other engines, through the same
fixed scenarios on one Mac, and writes numbers a later run can diff key by key
(HQ#7146 goal G0). It does no tuning and has no gate. It reports.

```
cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
  --ref SHA --artifact artifacts/screen-stream-eval/results.json [--arg=targets=rd,webrtc] [--arg=samples=200]
```

`.github/workflows/screen-stream-eval.yml` runs it every day at the feat-cmux-next tip. It
uploads `results.json` and a `summary.md` that shows each number's change against the last
scheduled run.

## Scenarios (fixed)

| Scenario | What runs on the host | What is measured |
| --- | --- | --- |
| key, pointer | the glass-to-glass marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`), as the existing benches use it | one key press or click, then the time until a decoded frame shows the next counter; p50, p95, lost (1 s) |
| idle | `scene.swift`: a 5000-line code file at 13 pt Menlo, full screen, still for 30 s | kbps and fps the viewer received (each phase's first second dropped) |
| typing | the same view, 12 characters a second typed into its second line for 20 s | kbps, fps, encode and decode ms |
| scroll | the file scrolling at 600 pt a second for 20 s | kbps, fps |
| ocr | the top of the file, still; the host's `screencapture -x -D 1` 3 s in | Vision OCR character error rate of the viewer's last decoded frame against the host screenshot; the host's own OCR error against the drawn text as a check of the OCR |

Changing a scenario changes what every earlier number means: give it a new schema version
(`SCHEMA` in `eval.py`) instead.

## Targets (pluggable)

A target is `targets/NAME.sh`, run as `bash targets/NAME.sh VERB ...` with `EVAL_ROOT` (the
checkout), `EVAL_BIN` (where built tools go), `EVAL_STATE` (the target's private scratch
directory, 0700) and, for latency, `EVAL_MARKER_LOG` (the marker's log: `marker-origin X,Y click-at X,Y`
and `stream width W px ... display (W, H)`). The verbs are:

| Verb | Does |
| --- | --- |
| `build` | builds its host and viewer into `EVAL_BIN` |
| `host-start`, `host-stop` | starts its host on this Mac's main display at its defaults, and returns once the host is ready; stops it |
| `latency INPUT SAMPLES OUT` | INPUT `key` or `pointer`: SAMPLES inputs on the marker through its viewer; OUT gets `{"g2g_ms": {"n", "p50", "p95", ...}, "lost", "split": {"input_to_capture_ms", "encode_ms", "network_ms", "decode_ms", "method"}}` |
| `window SECONDS FRAME GO OUT` | a viewer that sends nothing for SECONDS. It creates GO once its first frame shows, which starts the scene's timeline. FRAME gets the last decoded frame (PNG or PPM), and OUT gets `{"series": [{"unix_ms", "bytes", "frames", "decode_ms", "encode_ms"}], "encode_ms_window", "extra"}`, one row a second |

Today's targets:

- `rd`: cmux.rd/1 (`cmux-tui/crates/cmux-rd-host`, the Mac viewer's path). The host runs with
  `--bind 127.0.0.1` and no other flags, and `cmux-rd bench` is the viewer, with VideoToolbox
  decode. `bench --input none --duration-s N` is the passive window.
- `webrtc`: `CmuxVNCWebRTC` `ScreenStreamHost` (the iPhone's path). `cmux-vnc-host --capture`
  runs with the default device hub signaling. The viewers are `RdMarkerClickLatencyTests`
  (`CMUX_RD_MARKER_INPUT=key|click`) and `StreamWindowTests`.

Adding one (for example Petal, https://github.com/kiruna-labs/petal) means writing
`targets/petal.sh` with these verbs and passing `--arg=targets=rd,webrtc,petal`. Its numbers then
appear under `targets.petal` in the same schema.

## Results

`artifacts/screen-stream-eval/results.json` (schema `cmux.screen-stream-eval/1`, the docstring of
`eval.py`) and `summary.md`. Each target also leaves its raw files under
`artifacts/screen-stream-eval/NAME/`, on the worker: the latency and window JSON, `phases.jsonl`,
`host.png`, `viewer-frame`, `ocr.json` and its logs, with pairing links redacted.

What this slice does not cover yet: the viewer runs on the same Mac as the host, so the network
leg is loopback. A second Mac on the LAN is the next row. Real networks are G2.

## Needs

A console worker whose step processes hold Screen Recording and Accessibility. The hosts
capture with ScreenCaptureKit and inject input with CGEvent, and they inherit the step's grants.
`preflight.swift` checks both first. Without them the run writes `run.blocked` and exits 3, and
measures nothing.
