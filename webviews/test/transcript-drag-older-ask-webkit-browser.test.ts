// A pane drag of a chat that can load older history asks for no page of it early, in WebKit (the
// engine the app shows its chat in).
// test/support/transcriptDragOlder.ts has the cases.
import path from "node:path";
import { webkit } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { dragOlder } from "./support/transcriptDragOlder";

await requireBrowserLane("transcript-drag-older-ask-webkit-browser.test.ts", async () => {
  await dragOlder({
    file: "transcript-drag-older-ask-webkit-browser.test.ts",
    engine: webkit,
    engineName: "webkit",
    configFile: path.join(path.resolve(import.meta.dir, ".."), "vite.config.ts"),
  });
});
