// A chat that fits at one end of a divider drag and not at the other shows no cut-off top, no empty
// band and no jump.
// test/support/transcriptDragStays.ts has the cases and why they are split.
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragStays } from "./support/transcriptDragStays";

await requireBrowserLane("transcript-drag-stays-crossing-browser.test.ts", async () => {
  await dragStays({
    file: "transcript-drag-stays-crossing-browser.test.ts",
    shape: "crossing",
    engine: chromium,
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
