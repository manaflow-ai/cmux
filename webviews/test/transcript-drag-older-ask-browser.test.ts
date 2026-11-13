// A pane drag of a chat that can load older history asks for no page of it early, in Chromium.
// test/support/transcriptDragOlder.ts has the cases.
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragOlder } from "./support/transcriptDragOlder";

await requireBrowserLane("transcript-drag-older-ask-browser.test.ts", async () => {
  await dragOlder({
    file: "transcript-drag-older-ask-browser.test.ts",
    engine: chromium,
    engineName: "chromium",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
