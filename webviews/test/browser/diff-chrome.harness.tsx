// Browser harness for test/diff-chrome-browser.test.ts: the real diff viewer (toolbar pill, file header bar,
// code rows) over one small patch, under the page's own stylesheets. `?empty` opens it on the empty state
// ("No changes") instead; `?indicators=classic` draws the +/- signs instead of the bars.
import "../../src/pages/shared/desktop";
import "../../src/styles.css";
import { diffViewerLabelsFor } from "../../src/labels";
import { mountDiffSurface } from "../../src/surfaces/diffSurface";

const query = new URLSearchParams(location.search);
const patch = `diff --git a/src/upload.sh b/src/upload.sh\n--- a/src/upload.sh\n+++ b/src/upload.sh\n@@ -1,3 +1,3 @@\n #!/bin/sh\n-retries=3\n+retries=5\n done\n`;
const patchURL = URL.createObjectURL(new Blob([patch], { type: "text/plain" }));
const indicators = query.get("indicators");
const config = document.createElement("script");
config.id = "cmux-diff-viewer-config";
config.type = "application/json";
config.textContent = JSON.stringify({
  payload: {
    title: "uploader",
    ...(query.has("empty") ? { statusMessage: "No changes" } : { patchURL }),
    layout: "unified",
    layoutSource: "explicit",
    labels: diffViewerLabelsFor("en"),
    ...(indicators ? { viewerOptions: { diffIndicators: indicators } } : {}),
  },
});
document.head.append(config);
void mountDiffSurface(document.getElementById("root")!);
