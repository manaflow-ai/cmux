// DESKTOP-FEEL (R139) gate: every first-party page entry loads the shared desktop layer
// (src/pages/shared/desktop.ts) as its FIRST import, so its CSS comes before the page's own and
// the page can only opt content back in. A new page under src/pages fails here until it does.
// Entries outside src/pages that have not adopted the layer yet are listed with their owner; the
// test fails when one of them adopts it without leaving the list, so the list only shrinks.
import { expect, test } from "bun:test";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { installDom } from "./../settings/testDom";

const src = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/** First-party entries outside src/pages not on the layer yet, by owner (R139 rollout). */
const pendingAdoption: Record<string, string> = {
  "agent-session/acpmux/main.tsx": "ACP UI lead (agent pane)",
  "agent-activity/main.tsx": "ACP UI lead (agent activity)",
};

function firstImport(file: string): string | null {
  const text = readFileSync(file, "utf8");
  const match = /^\s*import\s+(?:[^"';]*\sfrom\s+)?["']([^"']+)["']/m.exec(text);
  return match ? match[1]! : null;
}

function layerSpecifier(file: string): string {
  const relative = path.relative(path.dirname(file), path.join(src, "pages/shared/desktop"));
  return relative.startsWith(".") ? relative : `./${relative}`;
}

test("every page under src/pages imports the desktop layer first", () => {
  const pages = readdirSync(path.join(src, "pages"), { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== "shared")
    .map((entry) => path.join(src, "pages", entry.name, "main.tsx"))
    .filter((file) => existsSync(file));
  expect(pages.length).toBeGreaterThan(5);
  for (const file of pages) {
    expect({ file: path.relative(src, file), first: firstImport(file) }).toEqual({
      file: path.relative(src, file),
      first: layerSpecifier(file),
    });
  }
});

test("pending entries outside src/pages still exist and have not adopted the layer silently", () => {
  for (const [entry, owner] of Object.entries(pendingAdoption)) {
    const file = path.join(src, entry);
    expect({ entry, owner, exists: existsSync(file) }).toEqual({ entry, owner, exists: true });
    expect({ entry, adopted: firstImport(file) === layerSpecifier(file) }).toEqual({ entry, adopted: false });
  }
});

test("the layer marks the document, turns spellcheck off and refuses unhandled drops", async () => {
  const restore = installDom();
  try {
    const { installDesktopLayer, isTitleBar, DESKTOP_LAYER_ATTRIBUTE } = await import("./desktop");
    installDesktopLayer(document);
    expect(document.documentElement.hasAttribute(DESKTOP_LAYER_ATTRIBUTE)).toBe(true);
    expect(document.documentElement.spellcheck).toBe(false);
    const drop = new Event("drop", { cancelable: true });
    window.dispatchEvent(drop);
    expect(drop.defaultPrevented).toBe(true);
    document.body.innerHTML = '<header data-titlebar><span id="t">Title</span><button id="b">x</button></header>';
    expect(isTitleBar(document.getElementById("t"))).toBe(true);
    expect(isTitleBar(document.getElementById("b"))).toBe(false);
  } finally {
    restore();
  }
});

test("the layer CSS: nothing selects by default; fields and .selectable content do", () => {
  const css = readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8");
  expect(css).toMatch(/:root\s*\{[^}]*user-select:\s*none/);
  expect(css).toMatch(/\.selectable,\s*\.selectable \*\s*\{[^}]*user-select:\s*text/);
  expect(css).toMatch(/input,\s*textarea,[^{]*\{[^}]*user-select:\s*text/);
  expect(css).toMatch(/-webkit-user-drag:\s*none/);
});
