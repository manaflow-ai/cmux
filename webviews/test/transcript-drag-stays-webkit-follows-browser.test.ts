// A chat many views long that follows its latest row keeps that row at the view's end in each frame
// of a divider drag, in WebKit.
// test/support/transcriptDragStays.ts has the cases and why they are split.
import path from "node:path";
import { webkit } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragStays } from "./support/transcriptDragStays";

await requireBrowserLane("transcript-drag-stays-webkit-follows-browser.test.ts", async () => {
  await dragStays({
    file: "transcript-drag-stays-webkit-follows-browser.test.ts",
    shape: "follows",
    engine: webkit,
    engineName: "webkit",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
