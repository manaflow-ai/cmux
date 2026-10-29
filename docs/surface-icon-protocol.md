# External terminal-tab icons

`surface.icon.set` and `surface.icon.clear` provide temporary, local-only decoration of an ordinary workspace terminal tab. They do not select a workspace, focus a terminal, run a command or change the provider's native brand icon. Browser, Dock, cloud/remote and relay targets are unsupported.

The cc-island plugin uses these methods when its **Sync cmux tab icons** option is enabled. The plugin owns Claude session state and artwork; cmux validates and renders generic SVG frame resources. No JavaScript, CSS animation, external images or network resources are executed. Frames play locally through Core Animation rather than per-frame socket updates.

## Set and renew

Send a v2 request with these parameters:

- `workspace_id`, `surface_id`: explicit UUIDs, never current-focus defaults or short handles.
- `owner_id`: a nonempty producer/session identity, at most 200 UTF-8 bytes.
- `expected_agent_pid`, `expected_process_start`: the current agent PID and its UTC, English `ps -o lstart=` timestamp with whitespace normalized. The process must match the panel's live registered generation, terminal device and foreground process group. Inherited environment IDs and saved checkpoints alone are insufficient.
- `ttl_seconds`: 5–120 seconds, default 30.
- `asset`: an object with `frames`, `loop` and optional `static_frame` (default 0). Each frame is `{ "svg": "<svg ...>...</svg>", "duration_ms": 100 }`.

An asset has 1–64 frames, each at most 16 KiB, with at most 512 KiB total SVG bytes. Each frame lasts 50–5000 ms; total duration is at most 30 seconds. Accepted SVG elements are `svg`, `g`, `path`, `rect` and `circle` with bounded geometry, transforms and literal colors. Text must be outlines. Declarations/entities, references, scripts, styles, images, filters and SVG-native animation elements are rejected. Frames are rasterized to 64×64 PNGs before display.

The first set returns `lease_token`, `revision` and `ttl_seconds`. Every later update/renewal supplies `lease_token` and `expected_revision`. To renew unchanged pixels, omit `asset`. Renewal does not restart animation. Another producer cannot take over an unexpired lease.

`cmux surface icon set --help` describes the CLI adapter, which reads an asset JSON file and sends its contents rather than exposing a local file to the socket API. Existing `cmux --json rpc surface.icon.set '<params>'` also works.

## Clear and expiry

`surface.icon.clear` requires explicit UUIDs, `owner_id`, `lease_token` and `expected_revision`. The old process need not remain alive to clear its own decoration. Unknown/stale ownership cannot clear a new lease.

A lease expires unless renewed; producers should renew a 30-second lease about every 10 seconds. Expiry, accepted terminal closure/detach and local terminal respawn remove the decoration. The current native provider mark remains underneath and is revealed on removal. Leases are not persisted or transferred between workspaces.

Accessibility Reduce Motion displays a static frame. Hidden or occluded icon views pause playback; one-shot completion icons retain their final frame rather than replaying on renewal.

## Verification status

The implementation includes parser, lease, SVG validation/rasterization, CLI, relay-denial and animated-view tests. A standalone harness rendered all 209 frames of the cc-island export through the actual pinned SwiftDraw 0.29.0 raster core. This is not a receipt for a full native app build or live socket/animation dogfood; those require a compatible full Xcode installation.
