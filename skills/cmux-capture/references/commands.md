# `cmux shot` and `cmux record`: flags, output, errors

Installed `cmux shot --help` and `cmux record --help` own the flag list. This
page covers what help cannot: the response fields, the error codes, and the
limits the app enforces.

## Screenshot

```
cmux shot [--format png|jpg] [--jpg] [--scale <n>] [--max-width <n>]
          [--quality <n>] [--region <x,y,w,h>] [--out <path>]
          [--label <text>] [--caption <text>] [--window <id|ref|index>]
```

Plain output is `<width>x<height> <bytes> <path>`. `--json` prints the
`window.screenshot` response:

| Field | Meaning |
| --- | --- |
| `path` | Absolute path written |
| `width`, `height` | Pixel size of the file, after `--scale` and `--max-width` |
| `bytes` | File size |
| `format` | `png` or `jpeg`; a jpeg file is named `.jpg` |
| `label` | Present when `--label` was given |
| `window` | Present when a window was named |

## Recording

```
cmux record [start] [--format mp4|gif] [--gif] [--fps <n>] [--max-seconds <n>]
            [--scale <n>] [--max-width <n>] [--region <x,y,w,h>] [--out <path>]
            [--label <text>] [--no-captions] [--window <id|ref|index>]
cmux record stop|status [--id <id>]
cmux record note [--id <id>] <text>
cmux record list
```

Plain output is `<id> <state> <frames> <path>`, with ` (<error>)` appended when a
recording ended badly. `--json` prints the status object:

| Field | Meaning |
| --- | --- |
| `id`, `state` | Recording id, and `recording`, `finished` or `failed` |
| `format`, `path` | `mp4` or `gif`, and the absolute path |
| `frames`, `seconds` | Frames captured, and the span they cover |
| `width`, `height` | Frame size |
| `notes` | The captions added so far |
| `fps_requested`, `max_seconds` | What was asked for |
| `fps_effective` | What the sampler managed, present once two frames span a nonzero time |
| `label` | Present when `--label` was given |
| `error` | Present when the recording failed |

A clip plays at the speed things happened even when `fps_effective` is well
below `fps_requested`, because each frame carries the time it was captured. A
low effective rate costs smoothness, not accuracy.

## Limits

The app owns them, so the CLI passes values through unchanged and an out of
range value comes back as an error naming the socket field.

| Flag | shot | record |
| --- | --- | --- |
| `--fps` | n/a | 1 to 30 (default 12 for mp4, 8 for gif) |
| `--max-seconds` | n/a | 0.5 to 120 (default 15) |
| `--scale` | 0.1 to 1.0 (default 1) | 0.1 to 1.0 (default 1 for mp4, 0.5 for gif) |
| `--max-width` | 64 to 8192 | 64 to 4096 for mp4, 64 to 1280 for gif (default none for mp4, 960 for gif) |
| `--quality` | 0.1 to 1.0 (default 0.8, jpg only) | n/a |
| `--region` | 8 to 100000 points per side | 8 to 100000 points per side |

A gif carries two more ceilings, both refused as `invalid_params` naming the
socket field. `--max-seconds` times `--fps` may not ask for more than 960
frames, so a two minute gif has to come down to 8 fps, and a frame may not
exceed 4000000 pixels after `--scale` and `--max-width`. An mp4 has neither
limit, so a long or large clip is an mp4 that the uploader converts.

## Window selection

Without `--window`, both commands take the frontmost cmux window. `--window`
accepts a window id, a ref such as `window:2`, or an index, the same handles
`cmux list-windows` prints. A handle that names nothing fails with `not_found`
rather than falling back to another window.

## Region

`--region x,y,w,h` is in window points from the window's top left, the same
coordinates in both commands and in a dogfood tour's `region`. Each side is
at least 8 points, and no number may pass 100000 points, which is far outside
any window and the shape a typo such as `--region 0,0,1e19,1e19` takes. The
rectangle is clipped to the window, so a region larger than the window yields
the window rather than black bars. A region that starts at the window's origin
is still a crop: it is the size that decides, not the offset. A window resized
mid-recording keeps the frame size it started with and its content is
letterboxed inside it, so the clip never stretches. A window that shrinks far
enough that the region no longer overlaps it is the one case that ends a clip
early: the crop has nothing left in it, so the recording stops in state
`failed` with `region lies outside the window`, keeping the frames it already
had.

## Error codes

These are socket response codes. An unknown `cmux record` subcommand is
rejected locally with `CLIError` before the CLI sends a socket request, so it
has no socket error code.

| Code | When |
| --- | --- |
| `invalid_params` | A value out of range, a malformed region, a region under 8 or over 100000 points, or an `--out` path that is relative, carries the wrong extension, is not a file, or is somewhere the recorder cannot create the file, such as a read-only volume |
| `not_found` | The named window does not exist, no cmux window is open, the window closed during the capture, the window has no capturable content, or the named recording is unknown or already stopped |
| `conflict` | A recording is already active when another recording is started |
| `unsupported` | The system cannot capture windows at all |
| `timeout` | The capture did not finish in time (20 seconds for a screenshot) |
| `internal_error` | The capture or the encode failed for another reason |

A recording that fails after it started does not fail the command: it stops,
keeps whatever frames it had, and ends in state `failed` with the reason in
`error`. A gif stopped early still produces a playable file.

## Files

Without `--out`, the file lands in a temporary directory with a name built from
the label and the time. With `--out`, the path is made absolute against the
caller's cwd, the directory is created if needed, and the capture is written to a
hidden sibling and moved into place only when it is complete. The extension has
to match the format, because a `.png` full of JPEG bytes is a file every later
tool misreads: `.png` for png, `.jpg` or `.jpeg` for jpg, `.mp4` for mp4 and
`.gif` for gif. `--out` picks the path, never the format, so `--out clip.gif`
without `--gif` is refused rather than quietly writing an mp4 under that name.
The socket itself takes only an absolute path; the CLI is what resolves a
relative one. An existing file at
that path is replaced at that moment and not before, and a directory there is
refused with `invalid_params` and left alone.

## Both commands in one place

The `window.record.*` and `window.screenshot` methods are release v2 methods, so
`cmux rpc window.screenshot '{"label":"x"}'` works too. Prefer the verbs; `rpc`
is for a param the CLI has no flag for yet.

One thing does not survive the drop to `rpc`: the socket's `window` param takes
a window id and nothing else, because the CLI is what turns a ref such as
`window:2` or an index into an id. `{"window":"window:2"}` comes back
`not_found`.
