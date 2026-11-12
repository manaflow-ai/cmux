// cmux-web-test-timeout: 240
// A measure for a "never merges" branch: the frame work of a dragged chat, in Chromium.
// test/support/transcriptDragCost.ts says what it reads.
import path from "node:path";
import { chromium } from "playwright";
import { dragCost } from "./support/transcriptDragCost";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-drag-cost-browser.test.ts", async () => {
  await dragCost({
    file: "transcript-drag-cost-browser.test.ts",
    engine: chromium,
    engineName: "chromium",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
