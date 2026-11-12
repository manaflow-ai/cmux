// A chat with a few rows, all in view, keeps its first row in place while the divider beside it is
// dragged, narrower and wider.
// test/support/transcriptDragStays.ts has the cases and why they are split.
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragStays } from "./support/transcriptDragStays";

await requireBrowserLane("transcript-drag-stays-fits-browser.test.ts", async () => {
  await dragStays({
    file: "transcript-drag-stays-fits-browser.test.ts",
    shape: "fits",
    engine: chromium,
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
