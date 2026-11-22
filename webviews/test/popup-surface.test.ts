import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// Dogfood 2026-10-08 (Leo, "all those popovers, the styling and such"): every composer and header
// popover and every menu draws one surface. Compact rows, small-radius rects, one subtle shadow and a
// short open from the trigger's side, all from ui/popupSurface.css; colors stay each surface's theme.

const css = (path: string) => readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");

/** The declarations of `selector`'s first rule in `text` (minified or not). */
function rule(text: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const body = new RegExp(`(?:^|[}\\s])${escaped}\\s*\\{([^}]*)\\}`, "m").exec(text)?.[1];
  if (body === undefined) throw new Error(`no rule for ${selector}`);
  return body;
}

/** Whether `selector` opens with `ui-popup-open` inside a `prefers-reduced-motion: no-preference` block. */
function opensWhenMotionAllowed(text: string, selector: string): boolean {
  const guard = /@media\s+\(\s*prefers-reduced-motion:\s*no-preference\s*\)\s*\{/g;
  for (let match = guard.exec(text); match; match = guard.exec(text)) {
    let depth = 1;
    let end = guard.lastIndex;
    for (; end < text.length && depth > 0; end += 1) {
      if (text[end] === "{") depth += 1;
      else if (text[end] === "}") depth -= 1;
    }
    const block = text.slice(guard.lastIndex, end - 1);
    for (const [, selectors, body] of block.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const listed = selectors!.split(",").map((part) => part.trim());
      if (listed.includes(selector) && /animation:\s*ui-popup-open var\(--ui-popup-open\)/.test(body!)) return true;
    }
  }
  return false;
}

const popups: [file: string, selector: string][] = [
  ["ui/ui.css", ".ui-popup"],
  ["agent-session/acpmux/styles.css", ".acpmux-menu"],
  ["agent-session/acpmux/styles.css", ".acpmux-context-pop"],
  ["agent-session/acpmux/styles.css", ".acpmux-slash-menu"],
  ["agent-session/acpmux/composerLocation.css", ".acpmux-access-menu"],
  ["agent-session/acpmux/header/header.css", ".ui-popup.acpmux-chat-menu-popover"],
  ["agent-session/acpmux/summary/summary.css", ".acpmux-summary-popover"],
  ["agent-session/acpmux/changes/changes.css", ".acpmux-file-menu-list"],
];

const rows: [file: string, selector: string][] = [
  ["ui/ui.css", ".ui-menu-item"],
  ["agent-session/acpmux/styles.css", ".acpmux-menu-item"],
  ["agent-session/acpmux/header/header.css", ".ui-menu-item.acpmux-chat-menu-item"],
  ["agent-session/acpmux/changes/changes.css", ".acpmux-file-menu-item"],
];

describe("one popup surface", () => {
  test("the surface: 28 px rows, small radii, one subtle shadow and a short open", () => {
    const surface = css("ui/popupSurface.css");
    const root = rule(surface, ":root");
    const value = (name: string) => new RegExp(`${name}:\\s*([^;]+);`).exec(root)?.[1]?.trim();
    expect(value("--ui-row-height")).toBe("28px");
    expect(Number.parseFloat(value("--ui-popup-radius") ?? "")).toBeLessThanOrEqual(8);
    expect(Number.parseFloat(value("--ui-row-radius") ?? "")).toBeLessThanOrEqual(6);
    const shadow = value("--ui-popup-shadow") ?? "";
    expect(shadow.replace(/\([^)]*\)/g, "").includes(",")).toBe(false);
    expect(surface).toContain("@keyframes ui-popup-open");
    expect(value("--ui-popup-open")).toBe("120ms");
  });

  test("every page with menus loads the surface; the agent pane, which skips ui.css, loads it too", () => {
    expect(css("ui/ui.css")).toMatch(/^(\/\*[\s\S]*?\*\/\s*)?@import "\.\/popupSurface\.css";/);
    // The shipped pane concatenates its stylesheets (no @import): the surface comes before the pane's.
    const build = readFileSync(new URL("../../scripts/cmux-next/build-agent-pane-web.sh", import.meta.url), "utf8");
    const surface = build.indexOf("webviews/src/ui/popupSurface.css");
    expect(surface).toBeGreaterThan(-1);
    expect(surface).toBeLessThan(build.indexOf('"$SRC/acpmux/styles.css"'));
    for (const entry of ["agent-session/acpmux/dev.tsx", "agent-session/acpmux-preview/main.tsx"]) {
      expect(css(entry)).toContain('import "../../ui/popupSurface.css";');
    }
  });

  for (const [file, selector] of popups) {
    test(`${selector} draws the shared surface and opens from its trigger`, () => {
      const body = rule(css(file), selector).replace(/:\s+/g, ":");
      expect(body).toContain("border-radius:var(--ui-popup-radius)");
      expect(body).toContain("var(--ui-popup-shadow)");
      expect(body).not.toMatch(/0 10px 30px/);
      expect(body).toMatch(/transform-origin:/);
      // Reduce Motion: the open runs only under prefers-reduced-motion: no-preference.
      expect(body).not.toMatch(/animation:/);
      expect(opensWhenMotionAllowed(css(file), selector)).toBe(true);
    });
  }

  for (const [file, selector] of rows) {
    test(`${selector} is a compact row`, () => {
      const body = rule(css(file), selector).replace(/\s+/g, "");
      expect(body).toContain("min-height:var(--ui-row-height)");
      expect(body).toContain("border-radius:var(--ui-row-radius)");
    });
  }
});
