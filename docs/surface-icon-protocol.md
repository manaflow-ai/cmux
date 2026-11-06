# External terminal-tab icons

`surface.icon.set` and `surface.icon.clear` provide retained, local-only decoration of an ordinary workspace terminal tab. They do not select a workspace, focus a terminal, run a command or change the provider's native brand icon. Browser, Dock, cloud/remote and relay targets are unsupported.

The cc-island plugin uses these methods when its **Sync cmux tab icons** option is enabled. The plugin owns Claude session state and artwork; cmux validates and renders generic SVG frame resources. No JavaScript, CSS animation, external images or network resources are executed. Frames play locally through Core Animation rather than per-frame socket updates.

## Set and update

Send a v2 request with these parameters:

- `workspace_id`, `surface_id`: explicit UUIDs, never current-focus defaults or short handles.
- `owner_id`: a nonempty producer/session identity, at most 200 UTF-8 bytes.
- `expected_agent_pid`, `expected_process_start`: the current process PID and its UTC, English `ps -o lstart=` timestamp with whitespace normalized. The process must still have that birth identity, belong to the current user, and match the target terminal's actual device and foreground process group. Provider PID metadata is not used as terminal ownership evidence: a workspace-wide provider key can be replaced by another tab. Inherited environment IDs and saved checkpoints alone are insufficient.
- `ttl_seconds`: optional positive integer seconds, up to the platform's `Int.max`. Omit it on a full set for an infinite lifetime. For example, `"ttl_seconds": 600` expires the icon after 10 minutes unless renewed.
- `asset`: an object with `frames`, `loop` and optional `static_frame` (default 0). Each frame is `{ "svg": "<svg ...>...</svg>", "duration_ms": 100 }`.

An asset has 1–64 frames, each at most 16 KiB, with at most 512 KiB total SVG bytes. Each frame lasts 50–5000 ms; total duration is at most 30 seconds. Accepted SVG elements are `svg`, `g`, `path`, `rect` and `circle` with bounded geometry, transforms and literal colors. Text must be outlines. Declarations/entities, references, scripts, styles, images, filters and SVG-native animation elements are rejected. Frames are rasterized to 64×64 PNGs before display.

A complete `asset` without `lease_token` or `expected_revision` sets or replaces the icon after live process/terminal authorization. This allows a restarted producer to recover without waiting for expiry. Every full replacement creates a new token and generation; the last successfully committed full set wins.

The response contains `lease_token`, `revision` and `persistent`. `persistent` is `true` only for an infinite lifetime; timed entries return `persistent: false` and `ttl_seconds` with the effective interval, not the remaining time. Indefinite entries omit `ttl_seconds`. Conditional updates supply the current `lease_token` and `expected_revision` and must match the current owner. Old or expired credentials cannot update or clear a replacement or revive an expired icon.

An asset-free update with matching credentials is a heartbeat. It increments the revision while preserving the token, generation, pixels and animation position. Without `ttl_seconds`, it inherits the current interval and renews a timed entry from the heartbeat; an indefinite entry stays indefinite. An explicit positive `ttl_seconds` switches to that interval. Conditional updates that include an asset also inherit the interval when TTL is omitted. A full set with an asset, no `lease_token` or `expected_revision`, and no TTL restores an infinite lifetime. No heartbeat is required for indefinite icons. Timed deadlines use a monotonic clock that includes time spent asleep.

`cmux surface icon set --help` describes the CLI adapter, which reads an asset JSON file and sends its contents rather than exposing a local file to the socket API. Existing `cmux --json rpc surface.icon.set '<params>'` also works. To opt into a timed icon:

```sh
cmux surface icon set --workspace "$WORKSPACE_UUID" --surface "$SURFACE_UUID" \
  --owner agent-status --pid "$AGENT_PID" --process-start "$PROCESS_START" \
  --asset-file icon.json --ttl 600
```

For a heartbeat, replace `--asset-file icon.json` with `--lease-token "$TOKEN" --revision "$REVISION"`; omit `--ttl` to retain the current interval. Use the revision from each successful response for the next heartbeat or clear.

## Clear and lifecycle

`surface.icon.clear` requires explicit UUIDs, `owner_id`, `lease_token` and `expected_revision`. The old process need not remain alive to clear its own icon generation. Unknown/stale ownership cannot clear a replacement. The socket accepts and validates `ttl_seconds` on clear for compatibility but does not apply it; the CLI does not accept `--ttl` on clear.

An indefinite icon remains until another accepted update, explicit clear, terminal closure/detach or local terminal respawn. A timed icon also disappears when its interval expires without a heartbeat. A failed update does not immediately clear an icon; a disconnected producer leaves an indefinite icon intact, while a timed icon still expires. The current native provider mark remains underneath and is revealed on removal. Icons are not persisted or transferred between workspaces; they do not survive cmux restart.

Explicit TTL values from legacy producers are now honored rather than ignored. Producers that want indefinite icons must omit `ttl_seconds` or `--ttl`; timed producers must renew before their interval expires.

Accessibility Reduce Motion displays a static frame. Hidden or occluded icon views pause playback; one-shot completion icons retain their final frame rather than replaying on unchanged updates.

## Verification status

The implementation includes parser, lease, SVG validation/rasterization, CLI, relay-denial and animated-view tests. A standalone harness rendered all 209 frames of the cc-island export through the actual pinned SwiftDraw 0.29.0 raster core. This is not a receipt for a full native app build or live socket/animation dogfood; those require a compatible full Xcode installation.
