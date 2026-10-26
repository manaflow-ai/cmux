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

// The Swift file that floats a page over the window -> every stylesheet that page's entry imports
// (paths under webviews/src). A new transparent overlay host fails the next test until it is here.
const POPUP_PAGES: Record<string, string[]> = {
  "Packages/macOS/CmuxNext/Sources/CmuxNextApp/IconPicker/IconPickerService.swift": ["pages/icon-picker/styles.css"],
  "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Pages/UpdateSurfaceIsland.swift": [
    // main.tsx is the bundle the popover opens (on #/surface/<kind>): its sheets are the document's.
    "pages/changelog/styles.css",
    "pages/changelog/updateSurfaces.css",
    "pages/changelog/surface.css",
  ],
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

// Swift source without comments (nested block comments too) and string literals (raw ones too), so
// a doc example names no host.
function swiftCode(text: string): string {
  let out = "";
  let depth = 0;
  let i = 0;
  while (i < text.length) {
    if (text.startsWith("/*", i)) {
      depth += 1;
      i += 2;
    } else if (depth > 0) {
      if (text.startsWith("*/", i)) depth -= 1;
      i += text.startsWith("*/", i) ? 2 : 1;
    } else if (text.startsWith("//", i)) {
      const end = text.indexOf("\n", i);
      i = end === -1 ? text.length : end;
    } else if (/^#*"/.test(text.slice(i, i + 8))) {
      // A string literal, raw (#"…"#, escapes \#) or not.
      const hashes = /^#*/.exec(text.slice(i))?.[0] ?? "";
      i += hashes.length;
      const quote = (text.startsWith('"""', i) ? '"""' : '"') + hashes;
      const escape = `\\${hashes}`;
      i += quote.length - hashes.length;
      while (i < text.length && !text.startsWith(quote, i)) i += text.startsWith(escape, i) ? escape.length + 1 : 1;
      i += quote.length;
      out += '""';
    } else {
      out += text[i];
      i += 1;
    }
  }
  return out;
}

function transparentOverlayHosts(): string[] {
  return swiftFiles(SWIFT_SOURCES)
    .filter((path) => /requiresWebKit:\s*\.transparentOverlay\b/.test(swiftCode(readFileSync(path, "utf8"))))
    .map((path) => relative(REPO, path))
    .sort();
}

test("a host named only in a comment or string is no host", () => {
  const text = [
    "/* outer /* inner */ requiresWebKit: .transparentOverlay */",
    'let doc = "requiresWebKit: .transparentOverlay"',
    'let raw = #"print("requiresWebKit: .transparentOverlay")"#',
    'let rawEscape = #"a \\#"b" requiresWebKit: .transparentOverlay"#',
    '"""\nrequiresWebKit: .transparentOverlay\n"""',
    "// requiresWebKit: .transparentOverlay",
    "let host = Host(requiresWebKit: .opaque)",
  ].join("\n");
  expect(swiftCode(text)).not.toContain("transparentOverlay");
  expect(swiftCode("Host(requiresWebKit: .transparentOverlay)")).toContain("transparentOverlay");
});

test("every page the app floats as a popup is listed with its document", () => {
  expect(transparentOverlayHosts()).toEqual(Object.keys(POPUP_PAGES).sort());
});

test("a pending popup document is a listed page that still fails the scan", () => {
  const listed = Object.values(POPUP_PAGES).flat();
  for (const file of Object.keys(PENDING)) {
    expect(listed).toContain(file);
    // Once its fix lands the document passes: drop it from PENDING so the scan covers it.
    expect(findOpaquePopupPageRoots([file]).length).toBeGreaterThan(0);
    expect(findOpaquePopupPageRoots([file])).not.toContain(`${file}: no such stylesheet under src/`);
  }
});

test("a popup page's root never paints an opaque fill", () => {
  // A page's stylesheets are one document: one of them clears html for all.
  const pages = Object.values(POPUP_PAGES).filter((page) => !page.some((file) => file in PENDING));
  expect(findOpaquePopupPageRoots(pages)).toEqual([]);
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
    put("list/styles.css", "html:is([data-surface], [data-ready]) { background: transparent; }\n");
    put("none/styles.css", "html { background: none; }\n");
    put("initial/styles.css", "html { background-color: initial; }\n");
    put("colornone/styles.css", "html { background-color: none; }\n");
    put(
      "child/styles.css",
      "html { background: transparent; }\nhtml[data-surface]>body { background: #fff; }\nbody.popup { background: #fff; }\n" +
        ":is(body, #root) { background: #fff; }\n:is(body, #root).popup { background: #fff; }\n" +
        ":where(body)[data-open] { background: #fff; }\n",
    );
    // One page's two stylesheets: the second clears html for both, the first paints body.
    put("split/base.css", "html[data-surface] body { background: #fff; }\n");
    put("split/surface.css", "html { background: transparent; }\n");
    put(
      "scoped/styles.css",
      "html[data-surface] { background: transparent; }\nhtml[data-surface] #root { display: flow-root; }\n",
    );
    put(
      "reduce/styles.css",
      "html { background: transparent; }\n@media (prefers-reduced-transparency: reduce) { body { background: Canvas; } }\n",
    );
    const found = findOpaquePopupPageRoots(
      [
        "solid/styles.css",
        "canvas/styles.css",
        "inherits/styles.css",
        "scoped/styles.css",
        "reduce/styles.css",
        "list/styles.css",
        "none/styles.css",
        "initial/styles.css",
        "colornone/styles.css",
        "child/styles.css",
        ["split/base.css", "split/surface.css"],
      ],
      dir,
    );
    expect(found).toEqual([
      "solid/styles.css:1: html, body { background: var(--cmux-surface-solid) }",
      "solid/styles.css: the popup document never paints html transparent (the page base paints the host's surface)",
      "canvas/styles.css:2: body { background-color: Canvas }",
      "inherits/styles.css: the popup document never paints html transparent (the page base paints the host's surface)",
      "colornone/styles.css: the popup document never paints html transparent (the page base paints the host's surface)",
      "child/styles.css:2: html[data-surface]>body { background: #fff }",
      "child/styles.css:3: body.popup { background: #fff }",
      "child/styles.css:4: :is(body, #root) { background: #fff }",
      "child/styles.css:5: :is(body, #root).popup { background: #fff }",
      "child/styles.css:6: :where(body)[data-open] { background: #fff }",
      "split/base.css:1: html[data-surface] body { background: #fff }",
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
