// The diff viewer page of the shared page host (`cmux-page://cmux.diff/`, diff-host.md S3). The
// host embeds no config: the surface asks `cmux.diff.config` over the cmuxPage bridge and renders
// when it answers. webviews/diff-page.html loads it; the one webviews-app build emits both, next to
// the shared chunks, highlight worker and WASM.
//
// The surface is a dynamic import, as in src/main.tsx: it lands in `chunks/diffSurface.mjs`, and
// the worker pool resolves `./diff-worker.mjs` beside that chunk.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
const root = document.getElementById("root");
if (!root) throw new Error("Missing cmux webview root");
import("../../surfaces/diffSurface")
  .then((surface) => surface.mountDiffSurface(root))
  .catch((error: unknown) => {
    document.documentElement.dataset.cmuxDiffBoot = "failed";
    console.error("cmux diff page boot failed", error);
  });
