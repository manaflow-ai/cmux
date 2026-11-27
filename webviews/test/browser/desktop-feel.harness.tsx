// Browser harness for test/desktop-feel.test.ts: the real diff viewer on the shared desktop layer
// (R139), loaded first as every page entry does, over a two-file patch.
import "../../src/pages/shared/desktop";
import "../../src/styles.css";
import { diffViewerLabelsFor } from "../../src/labels";
import { mountDiffSurface } from "../../src/surfaces/diffSurface";

function filePatch(name: string, lines: number): string {
  const body: string[] = [];
  for (let k = 0; k < lines; k += 1) {
    if (k % 4 === 1) {
      body.push(`-export const value_${k} = ${k};`, `+export const value_${k} = ${k * 2};`);
    } else {
      body.push(` export const value_${k} = ${k};`);
    }
  }
  return `diff --git a/${name} b/${name}\n--- a/${name}\n+++ b/${name}\n@@ -1,${lines} +1,${lines} @@\n${body.join("\n")}\n`;
}

const patchURL = URL.createObjectURL(
  new Blob([filePatch("src/selection/alpha.ts", 12), filePatch("src/selection/beta.ts", 12)], { type: "text/plain" }),
);
const config = document.createElement("script");
config.id = "cmux-diff-viewer-config";
config.type = "application/json";
config.textContent = JSON.stringify({
  payload: {
    title: "Desktop feel harness",
    patchURL,
    layout: "unified",
    layoutSource: "explicit",
    labels: diffViewerLabelsFor("en"),
  },
});
document.head.append(config);
void mountDiffSurface(document.getElementById("root")!);
