import { describe, expect, test } from "bun:test";
import {
  hasRawColor,
  inlineStyleFindings,
  isOutsideScale,
  ratchetErrors,
  tokenLiteralKind,
} from "../scripts/check-design-tokens";

describe("design token ratchet", () => {
  test.each([
    ["padding", "var(--ds-space-1) 13px", true],
    ["padding", "var(--ds-space-1) 12px", false],
    ["gap", "var(--ds-space-2, 7px)", true],
    ["gap", "var(--ds-space-2, 8px)", false],
    ["height", "var(--ds-control-compact, 13px)", true],
    ["height", "var(--ds-control-compact, 24px)", false],
    ["gap", "var(--ds-space-2)", false],
    ["gap", "6px", true],
    ["gap", "8px", false],
  ] as const)("checks %s: %s", (property, value, outside) => {
    expect(isOutsideScale(property, value)).toBe(outside);
  });

  test("checks literals next to a token in calc", () => {
    expect(isOutsideScale("gap", "calc(var(--ds-space-2) + 2px)")).toBe(true);
    expect(isOutsideScale("gap", "calc(var(--ds-space-2) + 4px)")).toBe(false);
  });

  test("rejects a new declaration in a previously clean bucket", () => {
    const errors = ratchetErrors(new Map([["src.css\tspacing\tgap", 1]]), new Map());
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("new design token violation");
  });

  test("requires a baseline shrink after a violation is removed", () => {
    const errors = ratchetErrors(new Map([["src.css\theight\theight", 1]]), new Map([["src.css\theight\theight", 2]]));
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("baseline can shrink");
  });

  test("accepts an unchanged baseline", () => {
    expect(
      ratchetErrors(new Map([["src.css\tspacing\tpadding", 2]]), new Map([["src.css\tspacing\tpadding", 2]])),
    ).toEqual([]);
  });

  test.each([
    ["color", "#fff", "color"],
    ["background", "rgba(0, 0, 0, 0.5)", "color"],
    ["border", "1px solid oklch(0.7 0.1 250)", "color"],
    ["box-shadow", "0 1px 0 color-mix(in srgb, #fff 6%, transparent)", "color"],
    ["color", "var(--cv-fg)", undefined],
    ["color", "var(--cv-fg, #fff)", undefined],
    ["background", "rgb(var(--accent-rgb) / 0.5)", undefined],
    ["background", "color-mix(in srgb, var(--cv-fg) 10%, transparent)", undefined],
    ["mask-image", "linear-gradient(#000, transparent)", undefined],
    ["--cv-fg", "#fff", undefined],
    ["margin", "6px 0", "spacing"],
    ["margin-top", "-4px", undefined],
    ["inset", "0 40px", undefined],
    ["top", "3px", "spacing"],
    ["border-radius", "7px", "radius"],
    ["border-radius", "5px", "radius"],
    ["border-radius", "8px 8px 0 0", undefined],
    ["border-radius", "999px", undefined],
    ["border-radius", "var(--cmux-menu-highlight-radius)", undefined],
    ["font-weight", "500", "font-weight"],
    ["font-weight", "700", "font-weight"],
    ["font-weight", "bold", "font-weight"],
    ["font-weight", "600", undefined],
    ["font-weight", "var(--weight-strong)", undefined],
    ["transition", "opacity 120ms", "duration"],
    ["transition", "opacity var(--cmux-motion-micro) var(--cmux-ease-out)", undefined],
    ["transition", "opacity var(--cmux-motion-micro) ease-out", "easing"],
    ["animation-duration", "0s", undefined],
    ["animation-timing-function", "cubic-bezier(0.2, 0.8, 0.2, 1)", "easing"],
    ["transition", "transform var(--cmux-motion-standard) linear", undefined],
  ] as const)("token literal %s: %s", (property, value, kind) => {
    expect(tokenLiteralKind(property, value)).toBe(kind);
  });

  test("a colour function composing a token is not a raw literal", () => {
    expect(hasRawColor("rgb(127 127 127 / 0.15)")).toBe(true);
    expect(hasRawColor("url(#mask) var(--x)")).toBe(false);
  });

  test("reads TSX inline style objects like the same CSS", () => {
    const source = `const A = () => <div style={{ padding: 6, marginTop: 4, borderRadius: open ? 7 : 8, color: "#123456", fontWeight: 500, transition: "opacity var(--cmux-motion-micro)", "--x": "#fff" }} />;`;
    expect(inlineStyleFindings("a.tsx", source).map((f) => [f.kind, f.property, f.value])).toEqual([
      ["spacing", "padding", "6px"],
      ["radius", "border-radius", "7px"],
      ["color", "color", "#123456"],
      ["font-weight", "font-weight", "500"],
    ]);
    expect(inlineStyleFindings("a.tsx", `<div style={{ gap: 8, borderRadius: 999, fontWeight: 600 }} />`)).toEqual([]);
  });

  test("a new token literal fails, an allowlisted one passes, and a fixed one must shrink the baseline", () => {
    const id = "x.css\tcolor\tcolor\t#fff";
    expect(ratchetErrors(new Map([[id, 1]]), new Map())[0]).toContain("new design token violation");
    expect(ratchetErrors(new Map([[id, 1]]), new Map([[id, 1]]))).toEqual([]);
    expect(ratchetErrors(new Map(), new Map([[id, 1]]))[0]).toContain("baseline can shrink");
  });
});
