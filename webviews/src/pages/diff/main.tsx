// The diff viewer page of the shared page host (`cmux-page://cmux.diff/`, diff-host.md S3). The
// host embeds no config: the surface asks `cmux.diff.config` over the cmuxPage bridge and renders
// when it answers. scripts/cmux-next/build-diff-page-web.sh bundles this entry with the highlight
// worker and the lazy shiki chunks.
//
// The surface is a dynamic import, as in src/main.tsx: it lands in `chunks/diffSurface.mjs`, and
// the worker pool resolves `./diff-worker.mjs` beside that chunk.
const root = document.getElementById("root");
if (!root) throw new Error("Missing cmux webview root");
import("../../surfaces/diffSurface")
  .then((surface) => surface.mountDiffSurface(root))
  .catch((error: unknown) => {
    document.documentElement.dataset.cmuxDiffBoot = "failed";
    console.error("cmux diff page boot failed", error);
  });
