// The browser rewraps a chat's rows in each frame of a divider drag, with no render of a row and no
// write of a row's place, in Chromium.
// test/support/transcriptDragFlows.ts has the cases and what they count.
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragFlows } from "./support/transcriptDragFlows";

await requireBrowserLane("transcript-drag-flows-browser.test.ts", async () => {
  await dragFlows({
    file: "transcript-drag-flows-browser.test.ts",
    engine: chromium,
    engineName: "chromium",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
