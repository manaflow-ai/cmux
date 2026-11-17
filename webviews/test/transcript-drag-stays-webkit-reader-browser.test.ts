// A reader scrolled up in a long chat keeps the row at the top of their view while the divider
// beside it is dragged, in WebKit.
// test/support/transcriptDragStays.ts has the cases and why they are split.
import path from "node:path";
import { webkit } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragStays } from "./support/transcriptDragStays";

await requireBrowserLane("transcript-drag-stays-webkit-reader-browser.test.ts", async () => {
  await dragStays({
    file: "transcript-drag-stays-webkit-reader-browser.test.ts",
    shape: "reader",
    engine: webkit,
    engineName: "webkit",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
