// The browser rewraps a chat's rows in each frame of a divider drag, with no render of a row and no
// write of a row's place, in WebKit.
// test/support/transcriptDragFlows.ts has the cases and what they count.
import path from "node:path";
import { webkit } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragFlows } from "./support/transcriptDragFlows";

await requireBrowserLane("transcript-drag-flows-webkit-browser.test.ts", async () => {
  await dragFlows({
    file: "transcript-drag-flows-webkit-browser.test.ts",
    engine: webkit,
    engineName: "webkit",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
