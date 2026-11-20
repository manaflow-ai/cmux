import { describe, expect, test } from "bun:test";
import {
  findTokenOnlyViolations,
  hasRawColor,
  inlineStyleFindings,
  isOutsideScale,
  ratchetErrors,
  tokenLiteralKind,
  tokenOnlyFindings,
  tokenOnlyKind,
  tsTokenCopies,
  scriptMotionFindings,
  motionLiteralsInText,
  motionScaleMatchers,
} from "../scripts/check-design-tokens";
import { designTokenValue, designTokens, tokenFor } from "../scripts/design-token-values";

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

  test("reads calc(N * var(--ui-px, 1px)) as N on the scale, not its 1px fallback", () => {
    expect(isOutsideScale("gap", "calc(8 * var(--ui-px, 1px))")).toBe(false);
    expect(isOutsideScale("padding-inline", "calc(8 * var(--ui-px, 1px)) calc(12 * var(--ui-px))")).toBe(false);
    expect(isOutsideScale("height", "calc(28 * var(--ui-px, 1px))")).toBe(false);
    expect(isOutsideScale("padding", "calc(6 * var(--ui-px, 1px))")).toBe(true);
    expect(isOutsideScale("height", "calc(34 * var(--ui-px, 1px))")).toBe(true);
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
    ["transition", "opacity 120ms", "duration"], // motion-allow: scanner fixture, a raw literal
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

  test("scans asserted style objects and right-hand || fallbacks", () => {
    const source = `const A = () => <div style={({ color: customColor || "#fff", marginTop: customMargin || 6 } as React.CSSProperties)} />;`;
    expect(inlineStyleFindings("asserted.tsx", source).map((f) => [f.kind, f.property, f.value])).toEqual([
      ["color", "color", "#fff"],
      ["spacing", "margin-top", "6px"],
    ]);
  });

  // cmux#39380 moved the settle 265 -> 180 ms by hand in 14 files: a script reads the generated scale.
  test("a script that hand-types a motion-scale step or curve is a motion-literal", () => {
    const source = [
      "const FOLD_MS = 180;", // motion-allow: fixture
      "el.animate(k, { duration: 120 });", // motion-allow: fixture
      'const css = "opacity 0.08s cubic-bezier(0.16, 1, 0.3, 1)";', // motion-allow: fixture
      "expect(fold.durationMs).toBe(240);", // motion-allow: fixture
      'const ok = "var(--cmux-motion-settle, 180ms)"; const wait = 180; const n = 90;', // motion-allow: fixture
      "// motion-allow: a debounce",
      "const DEBOUNCE_MS = 120;",
    ].join("\n");
    expect(scriptMotionFindings("a.ts", source).map((f) => [f.line, f.property, f.value])).toEqual([
      [1, "number", "180"],
      [2, "number", "120"],
      [3, "string", "0.08s"], // motion-allow: fixture
      [3, "string", "cubic-bezier(0.16, 1, 0.3, 1)"], // motion-allow: fixture
      [4, "number", "240"],
    ]);
  });

  // cmux#44271 review: the detector hard-coded 80/120/180/240 and the two curves, so a scale change in
  // motion-scale.json left it flagging retired values and missing new ones. It reads the JSON now.
  test("the motion-literal values follow motion-scale.json, not a copy in the detector", () => {
    const moved = motionScaleMatchers({
      steps: [{ ms: 90 }, { ms: 140 }],
      easeOut: [0.2, 0, 0.4, 1],
      settle: { ms: 200, bezier: [0.1, 0.9, 0.2, 1] },
      send: { ms: 0, ease: [0.1, 0.9, 0.2, 1] },
    });
    const text = [
      "90ms 0.14s 200 ms",
      "180ms 0ms", // motion-allow: a retired step, which the moved scale no longer flags
      "cubic-bezier(0.2, 0, 0.4, 1) cubic-bezier(0.1,0.9,0.2,1)",
      "cubic-bezier(0, 0, 0.58, 1)", // motion-allow: the retired ease-out, no longer flagged
    ].join(" ");
    expect([...moved.ms].sort((a, b) => a - b)).toEqual([90, 140, 200]);
    expect(motionLiteralsInText(text, moved)).toEqual([
      "90ms",
      "0.14s",
      "200 ms",
      "cubic-bezier(0.2, 0, 0.4, 1)",
      "cubic-bezier(0.1,0.9,0.2,1)",
    ]);
  });

  test("a new token literal fails, an allowlisted one passes, and a fixed one must shrink the baseline", () => {
    const id = "x.css\tcolor\tcolor\t#fff";
    expect(ratchetErrors(new Map([[id, 1]]), new Map())[0]).toContain("new design token violation");
    expect(ratchetErrors(new Map([[id, 1]]), new Map([[id, 1]]))).toEqual([]);
    expect(ratchetErrors(new Map(), new Map([[id, 1]]))[0]).toContain("baseline can shrink");
  });
});

// Token-only surfaces (check-design-tokens.ts TOKEN_ONLY_FILES): the unread marker and the jump
// pair are built from tokens alone (cmuxterm-hq docs/handbook/feature-thrown-in-without-design.md).
describe("token-only surfaces", () => {
  test.each([
    ["--cv-since-tint", "var(--cmux-status-unread, #3982f5)", "a colour literal"],
    ["color", "rgba(0, 0, 0, 0.4)", "a colour literal"],
    ["transition", "opacity 120ms ease-out", "a duration literal"], // motion-allow: scanner fixture, a raw literal
    ["transition", "opacity var(--agent-motion-in, 120ms) var(--agent-ease-out)", "a duration literal"], // motion-allow: scanner fixture, a raw literal
    ["transition", "opacity var(--agent-motion-in) cubic-bezier(0, 0, 0.58, 1)", "an easing literal"], // motion-allow: scanner fixture, a raw literal
    ["border-radius", "6px", "a radius that is not a token"],
  ] as const)("refuses %s: %s", (property, value, why) => {
    expect(tokenOnlyKind(property, value)).toBe(why);
  });

  test.each([
    ["color", "var(--unread-accent-text)"],
    ["--unread-wash", "color-mix(in srgb, var(--agent-text) 6%, transparent)"],
    ["transition", "opacity var(--agent-motion-calm) var(--agent-ease-out)"],
    ["border-radius", "var(--ds-radius-control)"],
    ["border-top", "var(--cmux-hairline-ring) solid var(--unread-accent)"],
  ] as const)("accepts %s: %s", (property, value) => {
    expect(tokenOnlyKind(property, value)).toBeUndefined();
  });

  test("a component's colour literal is refused outside comments only", () => {
    const source = `// #3982f5 in a comment\nconst style = { color: "#3982f5" };\n`;
    const findings = tokenOnlyFindings("x.tsx", source);
    expect(findings.map((finding) => finding.line)).toContain(2);
    expect(findings.some((finding) => finding.line === 1)).toBe(false);
  });

  test("the unread marker and the jump pair use tokens only", () => {
    expect(findTokenOnlyViolations().map((f) => `${f.file}:${f.line} ${f.property}: ${f.value}`)).toEqual([]);
  });
});

describe("token copies (a px/ms literal a named token already holds)", () => {
  test("reads single-valued :root px/ms tokens from the sheets", () => {
    expect(designTokenValue("--grid-half-step")).toBe("2px");
    expect(designTokenValue("--cmux-motion-quick")).toMatch(/^[0-9]+ms$/);
    // Defined with calc() (scales with the interface), so it is no single value.
    expect(() => designTokenValue("--grid-pill")).toThrow();
  });

  test("names the token for a value in its own family only", () => {
    expect(tokenFor("ui/x.css", "2px", "spacing", ".x", false)?.name).toBe("--grid-half-step");
    // 18px is the composer radius, never a gap.
    expect(tokenFor("ui/x.css", "18px", "spacing", ".x", false)).toBeUndefined();
    expect(tokenFor("ui/x.css", "18px", "radius", ".composer", false)?.name).toBe("--ds-radius-composer");
    // A component's token names only that component's values.
    expect(tokenFor("ui/x.css", "18px", "radius", ".card", false)).toBeUndefined();
    expect(tokenFor("ui/x.css", "0px", "spacing", ".x", false)).toBeUndefined();
  });

  test("a sheet's own token reaches only files under its folder", () => {
    const local = designTokens().find((token) => token.name === "--find-pill-height");
    expect(local?.surface).toBe("ui");
    expect(tokenFor("pages/feed/x.css", "34px", "size", ".find-pill", false)).toBeUndefined();
  });

  test("finds asserted and inline-style copies in tests and galleries, not other strings", () => {
    const findings = tsTokenCopies(
      "ui/x.test.tsx",
      [
        'expect(getComputedStyle(bar).gap).toBe("2px");',
        'expect(style.gap).not.toBe("2px");',
        'if (style.paddingTop !== "2px") throw new Error("x");',
        'const label = "2px";',
        'expect(rail.style.left).toBe("2px");',
        'expect(style.gap).toBe("8px");',
        'const el = <div style={{ gap: "2px", "--x": "2px" }} />;',
      ].join("\n"),
    );
    expect(findings.map((finding) => [finding.line, finding.property, finding.token])).toEqual([
      [1, "expect", "--grid-half-step"],
      [2, "expect", "--grid-half-step"],
      [3, "compare", "--grid-half-step"],
      [7, "style", "--grid-half-step"],
    ]);
  });

  test("a new copy is refused with the token to use", () => {
    const [finding] = tsTokenCopies("../test/x.test.ts", 'expect(style.gap).toBe("2px");');
    const id = ["../test/x.test.ts", "token-copy", "expect", "2px"].join("\t");
    const errors = ratchetErrors(new Map([[id, 1]]), new Map(), [finding!]);
    expect(errors[0]).toContain("new design token violation");
    expect(errors[1]).toContain('designTokenValue("--grid-half-step")');
  });
});
