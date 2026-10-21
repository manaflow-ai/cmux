// A gallery entry draws the agent pane's Tailwind utilities only as a pane entry (`pane: true`):
// the frame then loads the pane's shipped stylesheet, Tailwind included (dev-server/galleryHost.ts
// agentPaneCSS), as the app does. Without it the model picker showed as bare browser buttons in a
// column, nothing like the app's. A component that uses the pane's theme utilities (`text-fg`,
// `border-edge`, `bg-accent`, `shadow-menu`: acpmux/tailwind.css @theme) is drawn only by pane
// entries.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { loadEntrySources } from "../scripts/gallery/entries";

const SRC = path.resolve(import.meta.dir, "../src");
// Every color and shadow acpmux/tailwind.css names in its @theme (--color-*, --shadow-menu).
const PANE_UTILITY =
  /\b(?:(?:text|bg|border(?:-[trblxy])?|fill|stroke|ring|divide|outline|accent|caret)-(?:accent|base|dim|edge|fg|hover|menu|muted)|shadow-menu)\b/;

test("entries covering components with the pane's Tailwind utilities are pane entries", async () => {
  const usesPaneTailwind = (file: string) =>
    file.startsWith("agent-session/") &&
    fs.existsSync(path.join(SRC, file)) &&
    PANE_UTILITY.test(fs.readFileSync(path.join(SRC, file), "utf8"));
  const missing = (await loadEntrySources())
    .filter(({ entry }) => entry.host === "component" && !entry.pane)
    .filter(({ entry }) => (entry.covers ?? []).some((cover) => usesPaneTailwind(cover.split("#")[0]!)))
    .map(({ entry }) => entry.id)
    .sort();
  expect(missing).toEqual([]);
});
