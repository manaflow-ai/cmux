// A page the app floats as a menu, picker or popover (Swift `requiresWebKit: .transparentOverlay`)
// shows on the native glass the host draws behind it (Glass.makeOverlayPanel), so its document root
// never paints an opaque fill and paints its html transparent itself (Leo 2026-10-21: "why is this
// not glassed and themed right"). The in-page menus are glass.css's (popup-surface tests); the
// native hosts are scripts/cmux-next/check-overlay-glass.py's `popup-host` rule.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";

import { findOpaquePopupPageRoots } from "../scripts/check-glass-never-opaque";

const REPO = join(import.meta.dir, "../..");

// The Swift file that floats a page over the window -> that page's popup document stylesheets
// (paths under webviews/src). A new transparent overlay host fails the next test until it is here.
const POPUP_PAGES: Record<string, string[]> = {
  "Packages/macOS/CmuxNext/Sources/CmuxNextApp/IconPicker/IconPickerService.swift": ["pages/icon-picker/styles.css"],
  "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Pages/UpdateSurfaceIsland.swift": ["pages/changelog/surface.css"],
};

// Popup documents whose fix is in an open pull request that owns the file; each goes when it lands.
const PENDING: Record<string, string> = {
  "pages/icon-picker/styles.css": "#23066 paints html and body transparent (lucasr1b, menus and popovers glass)",
};

const SWIFT_SOURCES = join(REPO, "Packages/macOS/CmuxNext/Sources");

function swiftFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return swiftFiles(path);
    return entry.name.endsWith(".swift") ? [path] : [];
  });
}

function transparentOverlayHosts(): string[] {
  return swiftFiles(SWIFT_SOURCES)
    .filter((path) => /requiresWebKit:\s*\.transparentOverlay\b/.test(readFileSync(path, "utf8")))
    .map((path) => relative(REPO, path))
    .sort();
}

test("every page the app floats as a popup is listed with its document", () => {
  expect(transparentOverlayHosts()).toEqual(Object.keys(POPUP_PAGES).sort());
});

test("a popup page's root never paints an opaque fill", () => {
  const files = Object.values(POPUP_PAGES)
    .flat()
    .filter((file) => !(file in PENDING));
  expect(findOpaquePopupPageRoots(files)).toEqual([]);
});

test("the scan flags an opaque popup root and a root that never clears html", () => {
  const dir = mkdtempSync(join(tmpdir(), "popup-page-root-"));
  const put = (path: string, text: string) => {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  };
  try {
    put("solid/styles.css", "html, body { background: var(--cmux-surface-solid); }\n");
    put("canvas/styles.css", "html { background: transparent; }\nbody { background-color: Canvas; }\n");
    put("inherits/styles.css", "html, body, #root { height: 100%; }\n");
    put(
      "scoped/styles.css",
      "html[data-surface] { background: transparent; }\nhtml[data-surface] #root { display: flow-root; }\n",
    );
    put(
      "reduce/styles.css",
      "html { background: transparent; }\n@media (prefers-reduced-transparency: reduce) { body { background: Canvas; } }\n",
    );
    const found = findOpaquePopupPageRoots(
      ["solid/styles.css", "canvas/styles.css", "inherits/styles.css", "scoped/styles.css", "reduce/styles.css"],
      dir,
    );
    expect(found).toEqual([
      "solid/styles.css:1: html, body { background: var(--cmux-surface-solid) }",
      "solid/styles.css: the popup document never paints html transparent (the page base paints the host's surface)",
      "canvas/styles.css:2: body { background-color: Canvas }",
      "inherits/styles.css: the popup document never paints html transparent (the page base paints the host's surface)",
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
