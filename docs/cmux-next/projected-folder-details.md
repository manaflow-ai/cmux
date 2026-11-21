# Projected folder details experiment

`projected-folder-details` is registered in the webview Experiments registry. Its shipping arm is
`off`. In a development pane, set `cmux.experiments` in localStorage to a JSON object containing
`"projected-folder-details": "on"` (preserving other overrides), then reload the pane. Remove that
entry or choose `off` to restore ordinary startup details.

Start a Cloud chat with a local folder attached, then expand the startup disclosure. When that
start successfully projects the folder, its folder row shows the manifest file count, logical
size, and observed mount time. These are not downloaded or resident bytes. Copy fallback, a cached
retry without a mount receipt, and an older host without these fields keep the existing detail.
The experiment changes no transfer decision, permissions, byte budget, or projection default.

The Rust CLI reader validates the receipt before the native bridge forwards it. The shared pane
accepts only complete, nonnegative, safely representable counts on a successful folder operation.
No polling, filesystem scan, or network request is added.

Gallery: `agent-pane.projected-folder-details`, with projected, empty, and fallback variants and
an off/on comparison. Its script clicks the startup disclosure; fixture values are synthetic,
not benchmark measurements. Visual reference: the existing Cloud startup disclosure and
[the private projection design](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/rfd/0007-projected-folders.md).
