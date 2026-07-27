# Simulator panes

cmux can host one booted iPhone or iPad Simulator in a native pane. The pane renders live Simulator frames, forwards input, and exposes device tools without a browser server.

Create a pane from File > New Simulator Pane, the command palette, or the CLI:

```sh
cmux new-surface --type simulator --pane pane:1 --focus true
```

Choose an installed iPhone or iPad from the pane toolbar. cmux remembers its device identifier. If that identifier disappears, restoration requires an explicit device selection; saved runtime and device-type fields are descriptive metadata only.

## Input

- Click or drag inside the screen for taps, swipes, and drags.
- Hold Option while dragging for a two-finger pinch.
- Hold Option and Shift while dragging for a parallel two-finger pan.
- Use a mouse wheel or trackpad to send a paced touch scroll.
- Type with the physical keyboard. cmux forwards mapped keys and modifier chords.
- Use the rendered device buttons or Tools for Home, app switcher, Lock, Siri, and side-button input.
- Rotate from the toolbar or Tools. Input coordinates follow the displayed orientation.

The CLI uses normalized coordinates from `0` to `1`:

```sh
cmux simulator tap 0.5 0.5 --surface surface:1
cmux simulator tap --label General --role Button --surface surface:1
cmux simulator tap --identifier com.example.continue --surface surface:1
cmux simulator swipe 0.5 0.8 0.5 0.2 12 --surface surface:1
cmux simulator button home --surface surface:1
cmux simulator rotate landscape_left --surface surface:1
cmux simulator type 'Hello from cmux' --surface surface:1
```

Accessibility taps match one visible, enabled element by exact label or identifier, then tap its center. Add `--identifier` or `--role` when a label matches multiple elements.

`cmux ios` accepts every Simulator command. For stateful automation, capture a compact accessibility snapshot and use its `eN` refs:

```sh
cmux ios snapshot --surface surface:1 --json
cmux ios tap --ref e12 --surface surface:1 --json
cmux ios wait exists --label About --role cell --surface surface:1
cmux ios swipe --ref e20 up --duration 0.4 --surface surface:1
cmux ios drag --ref e8 right --surface surface:1
cmux ios long-press --ref e8 750 --surface surface:1
cmux ios type --ref e4 'Search text' --replace-existing --surface surface:1
cmux ios key 40 --surface surface:1
cmux ios keys 40,42 --delay 0.05 --surface surface:1
cmux ios gesture-preset swipe-from-left-edge --surface surface:1
cmux ios button apple-pay --surface surface:1
```

Snapshots include normalized roles, visible state, supported actions, a sequence number, and a screen hash. Pass `--since-screen-hash` to avoid retransmitting an unchanged tree. Refs expire after 60 seconds and are invalidated by input or other UI mutations. Each ref action verifies that the screen hash still matches before sending coordinate input, so app-driven changes fail with `UI_STATE_CHANGED` instead of tapping stale geometry. Successful JSON action results include the resolved action, a refreshed settled snapshot, and whether the screen hash changed.

Wait predicates are `exists`, `gone`, `enabled`, `focused`, `text-contains`, and `settled`. Select by ref or exact `--identifier`, `--label`, `--role`, and `--value` fields. A ref-based wait converts the ref to stable semantic fields before polling.

JSON failures include a machine-readable `ui_error` with an uppercase code, a recovery hint, and relevant refs, candidates, snapshot age, or timeout. Candidate lists are capped at 64 elements. Partial-text waits fail as ambiguous when matching elements contain different visible strings.

Batch taps resolve every ref against one snapshot before sending input:

```sh
cmux ios batch '[
  {"action":"tap","elementRef":"e3"},
  {"action":"tap","elementRef":"e7","postDelay":0.2}
]' --surface surface:1 --json
```

Use `touch --ref eN --down` and `touch --ref eN --up` for explicit touch phases. `--delay` is accepted only with both `--down` and `--up`. Named gestures support screen scrolling and swipes from each edge.

Programmatic touch actions render a Sky-kite cursor inside the targeted Simulator surface. The cursor marks held touches, follows timed gestures, pulses when a touch is released, and remains at the last agent touch point between actions. Its state belongs to the pane coordinator and resets when that pane changes devices or closes, so an action in one workspace cannot draw over another workspace or the desktop.

Run `cmux simulator` for gesture JSON, two-finger input, camera, permission, accessibility, Core Animation, and Web Inspector command syntax.

## Tools

The native Tools panel provides these device controls:

- Apps and media: list, install, launch, terminate, open URLs, add photos or videos, and read or write the pasteboard.
- Device state: rotate, send a memory warning, control the software keyboard, override the status bar, and change appearance or accessibility settings.
- Core Animation: show blended layers, copied images, misaligned images, offscreen rendering, or slow animations.
- Location: set a coordinate or replay built-in routes at walking, running, cycling, or driving speed with pause, loop, and restoration.
- Permissions: inspect, grant, revoke, or reset public and supported private permissions, including push notifications.
- Capture: save screenshots, record video, capture recent logs, or stream bounded live logs.
- Camera: inject an animated placeholder, image, looping video, or host camera into a user app. Sources and mirror mode can change without relaunching the app.
- Inspection: show the foreground app, browse and highlight the native accessibility tree, and send raw Web Inspector commands to Safari or `WKWebView` targets.
- Activity: review the bounded event history for the selected device.

These controls cover the iPhone and iPad device capabilities in [serve-sim](https://github.com/EvanBacon/serve-sim). Browser streaming, browser DevTools presentation, tunneling, Apple Watch, and attach-all fleet controls are outside the pane's scope.

## Crash containment

Private CoreSimulator, SimulatorKit, Indigo, HID, accessibility, camera, and Web Inspector work runs in a supervised child process. The worker resolves framebuffer GPU synchronization and writes a permission-restricted packed-BGRA ring. cmux copies stable slots off-main into immutable images and never gives Core Animation worker-owned storage.

The first worker crash restarts the selected device session. A second consecutive crash trips a fuse and leaves cmux responsive with the last safe frame. Use Recover in the pane or call the recovery RPC to start a fresh session:

```sh
cmux rpc simulator.recover '{"surface_id":"surface:1"}'
```

Recovery completes only after the replacement worker reports a live frame stream. Closing the pane joins pending cleanup, releases held input, stops capture helpers, and removes its shared-memory names.
