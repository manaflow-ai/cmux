// The composer's attachment row, as the shipped pane styles it: the stylesheets
// scripts/cmux-next/build-agent-pane-web.sh concatenates, in its order, with the last declaration
// of a property winning. Lawrence (2026-10-06): a thumbnail sat tight in the composer's top-left
// corner and its × hung over the thumbnail's edge and the composer's border.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dir, "../../../..");
const build = readFileSync(path.join(root, "scripts/cmux-next/build-agent-pane-web.sh"), "utf8");
const sheets = [...build.matchAll(/"\$SRC\/(acpmux\/[^"]+\.css)"/g)].map((match) => match[1]);
const css = sheets
  .map((sheet) => readFileSync(path.join(root, "webviews/src/agent-session", sheet), "utf8"))
  .join("\n")
  .replace(/\/\*[\s\S]*?\*\//g, "");

/// The declarations for exactly `selector`, merged in source order.
function rule(selector: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = match[1].split(",").map((part) => part.trim().replace(/\s+/g, " "));
    if (!selectors.includes(selector)) continue;
    for (const declaration of match[2].split(";")) {
      const at = declaration.indexOf(":");
      if (at > 0) out[declaration.slice(0, at).trim()] = declaration.slice(at + 1).trim();
    }
  }
  return out;
}
/// A length in px, with one level of `var(--name)` or `var(--name, fallback)` resolved on `scope`.
function px(value: string | undefined, scope: Record<string, string>): number {
  const resolved = (value ?? "").replace(
    /var\((--[\w-]+)(?:,\s*([^)]+))?\)/g,
    (_, name, fallback) => scope[name] ?? fallback ?? "",
  );
  if (resolved.trim() === "0") return 0;
  const number = /^(-?[\d.]+)px$/.exec(resolved.trim());
  if (!number) throw new Error(`not a px length: ${value} -> ${resolved}`);
  return Number(number[1]);
}

describe("composer attachments", () => {
  const box = rule(".acpmux-composer-box");
  const row = rule(".acpmux-attachments");
  const field = rule(".acpmux-md-field");

  test("the row sits inside the composer at the text's horizontal inset, on top and both sides", () => {
    const [top, right, bottom] = (row.padding ?? "").split(/\s+/);
    const textInset = px(field.padding?.split(/\s+/)[1], box);
    expect(px(top, box)).toBe(textInset);
    expect(px(right, box)).toBe(textInset);
    expect(px(bottom ?? "0px", box)).toBe(0);
  });

  test("attachments keep a gap between them", () => {
    expect(px(row.gap, box)).toBeGreaterThanOrEqual(8);
  });

  test("a thumbnail's corners nest in the composer's: its radius is the composer's less the inset", () => {
    const radius = rule(".acpmux-attachment")["border-radius"] ?? "";
    expect(radius).toContain("var(--acpmux-attach-radius)");
    expect(box["--acpmux-attach-radius"]).toMatch(
      /calc\(var\(--acpmux-composer-radius[^)]*\) - var\(--acpmux-attach-inset\)\)/,
    );
    expect(box["border-radius"]).toBe("var(--acpmux-composer-radius)");
  });

  test("the remove button is inside the thumbnail, at least 20px, in theme colors", () => {
    const remove = rule(".acpmux-composer .acpmux-attachment-remove");
    expect(px(remove.top, box)).toBeGreaterThanOrEqual(0);
    expect(px(remove.right, box)).toBeGreaterThanOrEqual(0);
    const size = px(remove.width, box);
    expect(size).toBeGreaterThanOrEqual(20);
    expect(px(remove.top, box) + size).toBeLessThanOrEqual(56);
    for (const property of ["background", "color"]) {
      expect(`${property}: ${remove[property]}`).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(/i);
      expect(remove[property]).toMatch(/var\(--(agent|acpmux)-/);
    }
    expect(rule(".acpmux-composer .acpmux-attachment-remove:hover").background).toMatch(/var\(--(agent|acpmux)-/);
    expect(rule(".acpmux-composer .acpmux-attachment-remove:focus-visible").outline).toContain("var(--agent-text)");
  });

  test("a file chip leaves room for the remove button", () => {
    const remove = rule(".acpmux-composer .acpmux-attachment-remove");
    const file = rule(".acpmux-attachment-file");
    const rightPadding = px(file.padding?.split(/\s+/)[1], box);
    expect(rightPadding).toBeGreaterThanOrEqual(px(remove.width, box) + px(remove.right, box));
  });
});
