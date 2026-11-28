// The popup surface token (`--surface-popup`) lives in pages/shared/desktop.css. The agent pane's
// dev previews load ui/popupSurface.css without a page, so they must load desktop.css too, or
// every popup there has no background at all.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const source = path.resolve(import.meta.dir, "../src");

test("every dev entry that loads the popup surface also loads the token it reads", () => {
  const missing = ["agent-session/acpmux/dev.tsx", "agent-session/acpmux-preview/main.tsx"].filter((file) => {
    const text = fs.readFileSync(path.join(source, file), "utf8");
    const popup = text.indexOf("ui/popupSurface.css");
    const desktop = text.indexOf("pages/shared/desktop.css");
    return popup >= 0 && (desktop < 0 || desktop > popup);
  });
  expect(missing).toEqual([]);
});
