const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// The desktop webview bundle only hosts the diff viewer. Agent Chat owns its
// rendering and transport in the native/mobile surfaces; keeping a second
// retired entry here caused the retired GUI to remain reachable.
void import("./surfaces/diffSurface").then((surface) => {
  surface.mountDiffSurface(rootElement);
});
