# Release media capture

Captures the screenshot or looping clip for one changelog feature on a fleet
Mac, then writes it where the changelog page expects it:
`web/public/changelog/<version>/<slug>.{png,mp4,webm}` plus a `-poster.png`,
and the feature's `image` or `video` entry in
`web/app/[locale]/(landing)/docs/changelog/changelog-media.ts`. The media
convention itself is in that file's header.

## Run it

```bash
scripts/release-media/release_media.py scripts/release-media/scenes/0.64.25/light-mode-terminals.json --host <capture-mac>
```

`<capture-mac>` is an SSH host name. Keep that Mac out of other GUI work (CI, soaks) for the run; the agent also refuses to start while another capture, a soak, or another `cmux NIGHTLY` is running there.

- `--allow-1x` captures on a 1x display; without it the tool stops and prints the host ask.
- `--dry-run` captures and encodes but leaves `web/` alone. `--workdir DIR` keeps the raw frames, the lossless master, and `receipt.json`.
- `--keep-app` leaves the nightly running on the host for poking at a scene.

A run takes about 30 s on the host, then the encode runs locally at low priority (`nice`).

## What happens

1. `host_agent.py` is piped to `ssh <host> python3 -` (the system Python 3.9, standard library only).
2. The agent checks the host: the SSH user owns the GUI session, the display scale, a capture backend, and that no other `cmux NIGHTLY` or soak is running (a second copy of the nightly bundle would terminate the first).
3. It downloads `cmux-nightly-macos-<arch>.dmg` on the host itself (conditional on a newer upload) and copies the app to `~/release-media/nightly/<arch>/<build>/`. Nothing is relayed through the operator's Mac.
4. It launches that copy with a private socket (`CMUX_SOCKET_MODE=allowAll`, `CMUX_SOCKET_PATH`) and a clean zsh (`ZDOTDIR` holding the scene's `zshrc`), merges the scene's settings into `~/.config/cmux/cmux.json`, opens a fresh window at the scene size, and runs the scene steps with the nightly's own `cmux` CLI.
5. It captures that window by its CGWindowID, then restores `cmux.json`, closes the window, and quits the copy it launched (matched by exact executable path; nothing else is touched). This cleanup also runs on SIGHUP/SIGTERM, and a lock file keeps one capture per host.
6. `release_media.py` copies the raw capture back, encodes it, writes the files, and patches `changelog-media.ts` (it fails if the version or feature is not there yet: write the recap first).

### Capture backends

| Backend | Used when | Still | Clip |
| --- | --- | --- | --- |
| `native` | the SSH session has Screen Recording (`CGPreflightScreenCaptureAccess` and a test `screencapture`) | `screencapture -x -o -l <id>` | `screencapture -v -V <secs> -l <id>`, full frame rate |
| `helper` | an approved `CuaSshScreenCapture.app` (the cua-ssh GUI capture helper) is in `~/Applications` | helper `window <id>` | one helper `window <id>` frame at a time, about 6 fps, retimed to 30 fps |

Both capture the window alone, so dialogs or banners stacked over it never appear. Clips flatten the window's transparent corners onto `output.matte` (default `#fafafa`, the site's light background); PNG stills keep them transparent.

### Encoding

- Stills: copied as captured, or scaled down to `output.width` (default 1600). Never upscaled.
- Clips: a lossless 30 fps master, then H.264 (`yuv420p`, `+faststart`) and VP9 WebM, each stepped down in quality until it fits 2 MB, and a poster PNG at `capture.posterAt`.

## Scene files

One JSON file per feature at `scenes/<version>/<slug>.json`:

```json
{
  "version": "0.64.25",
  "feature": "Light Mode Terminals",
  "slug": "light-mode-terminals",
  "window": { "width": 1200, "height": 675 },
  "zshrc": "PROMPT='%F{blue}~/project%f %# '\n",
  "settings": { "app": { "appearance": "dark" } },
  "setup": [
    { "cmux": ["new-split", "right", "--window", "{window}"], "save": "right" },
    { "cmux": ["send", "--surface", "{right}", "ls\\n"] },
    { "sleep": 1 }
  ],
  "capture": {
    "type": "clip",
    "seconds": 8,
    "posterAt": 6,
    "during": [{ "at": 3, "settings": { "app": { "appearance": "light" } } }]
  }
}
```

- `feature` must match a `title` in that version's `changelogMedia` entry.
- `window` is in points. At 2x a 1200x675 window becomes 2400x1350 px and is scaled to 1600 wide.
- `zshrc` is the whole shell setup for every terminal in the scratch app: prompt, aliases, and small functions that keep the typed demo commands short.
- `settings` is merged into `cmux.json` before launch and restored afterwards.
- Steps take exactly one of `cmux` (arguments to the nightly's `cmux` CLI), `sleep` (seconds), or `settings` (merge, then `cmux reload-config`). `{window}` is the scene window; `save` keeps the handle a creation command prints (`OK surface:7 ...`) for later steps. In `send` text, `\\n` is Enter.
- `capture.type` is `screenshot` or `clip` (5-10 s). `during` steps run at `at` seconds into the clip.
- Optional: `tryIt` (added when the feature has none), `output.width`, `output.matte`, `notes`.

## Host requirements

The tool prints the relevant operator step when a host falls short.

- Screen Recording for the capture process: `CuaSshScreenCapture.app` approved once under Screen & System Audio Recording, or `sshd-keygen-wrapper` for direct SSH captures.
- A HiDPI display for 2x output. A headless Mac mini drives 1920x1080 at 1x, so captures come out at half the resolution the site expects until it gets a 4K dummy plug or a virtual HiDPI display.
- A logged-in, unlocked GUI session for the SSH user.
- `cmux.json` may hold comments; the agent reads it as JSONC, writes the merged scene settings as plain JSON, and puts the original bytes back afterwards.

## Tests

```bash
python3 tests/test_release_media.py -v
```
