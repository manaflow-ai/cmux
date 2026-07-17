import { describe, expect, it } from "vitest";
import type { RenderRun, RenderUnderline } from "cmux/browser";
import { renderAttrs, runPresentation } from "../src/lib/renderStyles";

function run(overrides: Partial<RenderRun> = {}): RenderRun {
  return { text: "x", fg: null, bg: null, attrs: 0, ...overrides };
}

describe("render run presentation", () => {
  it("maps attribute bits to classes and combines strike with underline", () => {
    const attrs = Object.values(renderAttrs).reduce((all, bit) => all | bit, 0);
    const presentation = runPresentation(run({ attrs, underline: "curly" }), "#eeeeee", "#111111");

    expect(presentation.className).toContain("render-run-bold");
    expect(presentation.className).toContain("render-run-italic");
    expect(presentation.className).toContain("render-run-strikethrough");
    expect(presentation.className).toContain("render-run-dim");
    expect(presentation.className).toContain("render-run-invisible");
    expect(presentation.className).toContain("render-run-blink");
    expect(presentation.className).toContain("render-underline-curly");
    expect(presentation.style.textDecorationLine).toBe("underline line-through");
  });

  it.each([
    ["single", "render-underline-single"],
    ["double", "render-underline-double"],
    ["curly", "render-underline-curly"],
    ["dotted", "render-underline-dotted"],
    ["dashed", "render-underline-dashed"],
  ] satisfies [RenderUnderline, string][]) ("maps %s underline", (underline, className) => {
    expect(runPresentation(run({ underline }), "#eeeeee", "#111111").className).toContain(className);
  });

  it("uses snapshot defaults for null colors and swaps resolved colors for inverse", () => {
    const normal = runPresentation(run(), "#eeeeee", "#111111");
    const inverse = runPresentation(run({ attrs: renderAttrs.inverse, fg: "#ff0000" }), "#eeeeee", "#111111");

    expect(normal.style).toMatchObject({ color: "#eeeeee", backgroundColor: "#111111" });
    expect(inverse.style).toMatchObject({ color: "#111111", backgroundColor: "#ff0000" });
  });

  it("makes width_hint authoritative in measured cell units", () => {
    expect(runPresentation(run({ text: "界", width_hint: 2 }), "#eeeeee", "#111111").style.width)
      .toBe("calc(var(--render-cell-width) * 2)");
  });
});
