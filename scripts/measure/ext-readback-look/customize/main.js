// The NIGHTLY read-back probe's status item: one line of text in the window's titlebar.
function renderStatus() {
  return HStack([Text("RBPROBE live")])
}
globalThis.__cmuxAppExports = { renderStatus }
