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

  // Leo (dogfood 2026-10-08, 22-composer-image-chip.png): the × was oversized and sat over the
  // corner. It is a small (16px) × inside the corner, shown while the chip is hovered or focused.
  test("the remove button is a small × inside the thumbnail's corner, in theme colors", () => {
    const remove = rule(".acpmux-composer .acpmux-attachment-remove");
    expect(px(remove.top, box)).toBeGreaterThanOrEqual(3);
    expect(px(remove.right, box)).toBeGreaterThanOrEqual(3);
    const size = px(remove.width, box);
    expect(size).toBe(16);
    expect(px(remove.height, box)).toBe(16);
    expect(px(remove.top, box) + size).toBeLessThanOrEqual(56);
    for (const property of ["background", "color"]) {
      expect(`${property}: ${remove[property]}`).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(/i);
      expect(remove[property]).toMatch(/var\(--(agent|acpmux)-/);
    }
    expect(rule(".acpmux-composer .acpmux-attachment-remove:hover").background).toMatch(/var\(--(agent|acpmux)-/);
    expect(rule(".acpmux-composer .acpmux-attachment-remove:focus-visible").outline).toContain("var(--agent-text)");
  });

  test("the × shows only while the chip is hovered or holds the focus", () => {
    expect(rule(".acpmux-composer .acpmux-attachment-remove").opacity).toBe("0");
    expect(rule(".acpmux-attachment:hover .acpmux-attachment-remove").opacity).toBe("1");
    expect(rule(".acpmux-attachment:focus-within .acpmux-attachment-remove").opacity).toBe("1");
  });

  // Leo (dogfood 2026-10-08): the caret drew over the top of the preview. The row is its own band
  // above the field: in the composer's column it neither grows (a 100% basis is the box's height)
  // nor shrinks under its thumbnails, and it never scrolls vertically.
  test("the row is a fixed band above the prompt, never squeezed under the field", () => {
    expect(row.flex).toBe("none");
    expect(row["flex-basis"]).toBeUndefined();
    expect(row["overflow-y"]).toBe("hidden");
  });

  test("a thumbnail fills its square: the image is cropped, not letterboxed", () => {
    const image = rule(".acpmux-attachment-image img");
    expect(image["object-fit"]).toBe("cover");
    expect(image.width).toBe("100%");
    expect(image.height).toBe("100%");
  });

  test("a file chip leaves room for the remove button", () => {
    const remove = rule(".acpmux-composer .acpmux-attachment-remove");
    const file = rule(".acpmux-attachment-file");
    const rightPadding = px(file.padding?.split(/\s+/)[1], box);
    expect(rightPadding).toBeGreaterThanOrEqual(px(remove.width, box) + px(remove.right, box));
  });
});
