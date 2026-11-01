# Native UI layer host

The native loop is a small Debug-only SwiftUI executable. It compiles the
real `CmuxNextUiLayerPreview` leaf product, renders sample data from a
read-only projection, and restarts the host after a Swift source save. It does
not inject code or resources into a running cmux app.

From a checkout on a fleet Mac or capture slot:

```sh
CMUX_UI_LAYER_TRACE=1 Prototypes/UiLayerHost/launch.sh \
  --snapshot /tmp/cmux-ui-layer.json \
  --watch
```

For a read-only live projection, use `--attach` with the current-user Debug/DEV
control socket. The adapter permits only `system.identify`, `snapshot.get`, and
`events.stream`; it stops on an identity or event-stream reset.

The package dependency is deliberately narrow, and the checked-in watcher
follows the host plus each dependency source directory:

```text
UiLayerHost -> CmuxNextUiLayerPreview -> CmuxNextDesign, CmuxNextIcons
```

The preview product is not a dependency of `CmuxNextApp`, is compiled only in
the Debug configuration (`CMUX_UI_LAYER_PREVIEW`), is not included in release
app builds, and has no daemon or mutation-capable model. A one-line
change in a real view under `CmuxNextDesign` should therefore rebuild the leaf
module and relaunch the host. The watcher emits `ui-layer.reload`, and the host
emits `ui-layer.frame rendered_at_ns=...` on its first rendered frame; capture
both lines in the same recording.

Record one baseline and one edit on the same fleet Mac:

```text
host launch -> source save -> ui-layer.reload -> host frame
```

The acceptance target is a changed real-view line visible in under about 10 s.
The trace command above is required for the receipt: the watcher logs the save
request, and the host logs its first completed AppKit display pass.
Report the commit, fleet host, source file, `ui-layer.reload` timestamp, frame
timestamp, and total elapsed time. Do not run this build or capture on Air Blue.

For a host-side recording without Screen Recording permission, set the
capture-only `CMUX_UI_LAYER_CONTROL_SOCKET` path and call `debug.window_record`
with `{dir, seconds}`. This socket is separate from `CMUX_SOCKET_PATH`, so the
host cannot take over cmux's live control socket.
