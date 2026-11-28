// SUBJECT-IS (scripts/postcss/splitSubjectIs.mjs): no stylesheet ships a selector whose subject is a splittable
// `:is(...)`, because Blink files such a rule under no class and matches it against every element of every restyle
// (82.5% of the agent pane's selector matching in bench replay-under-load, with the other unfiled subjects).
//
// The detector: every stylesheet under src/ through the build's postcss plugins, then Lightning CSS minified at
// Vite's default build targets, has no selector `splitSubject` would split.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { Glob } from "bun";
import { transform } from "lightningcss";
import postcss from "postcss";
import focusRingGate from "../scripts/postcss/focusRingGate.mjs";
import splitHasLists from "../scripts/postcss/splitHasLists.mjs";
import splitSubjectIs, { plainSpecificity, splitSubject } from "../scripts/postcss/splitSubjectIs.mjs";

const webviews = path.resolve(import.meta.dir, "..");
const v = (major: number, minor = 0) => (major << 16) | (minor << 8);
const VITE_TARGETS = { chrome: v(111), edge: v(111), firefox: v(114), safari: v(16, 4), ios_saf: v(16, 4) };

function built(css: string, from: string | undefined): string {
  const out = postcss([focusRingGate(), splitSubjectIs(), splitHasLists()]).process(css, { from }).css;
  return transform({
    code: Buffer.from(out),
    filename: from ?? "a.css",
    minify: true,
    targets: VITE_TARGETS,
    errorRecovery: true,
  }).code.toString();
}

function selectors(css: string): string[] {
  const out: string[] = [];
  postcss.parse(css).walkRules((rule) => {
    out.push(...rule.selectors);
  });
  return out;
}

describe("split-subject-is", () => {
  test("a subject :is of same-specificity compounds splits, keeping prefix and suffix", () => {
    expect(splitSubject(".row :is(.a, .b):hover")).toEqual([".row .a:hover", ".row .b:hover"]);
    expect(splitSubject(":is(.acpmux-composer, .nt-composer, .nt-popover)")).toEqual([
      ".acpmux-composer",
      ".nt-composer",
      ".nt-popover",
    ]);
    expect(splitSubject(".p > :is(button.x, a.y)")).toEqual([".p > button.x", ".p > a.y"]);
    expect(splitSubject(":is(.a, .b):is(:hover, :focus-visible)")).toEqual([
      ".a:is(:hover, :focus-visible)",
      ".b:is(:hover, :focus-visible)",
    ]);
  });

  test("it leaves alone what could change the cascade or the match", () => {
    // Different specificity: `:is` takes the highest.
    expect(splitSubject(":is(.a, .b.c)")).toBeUndefined();
    expect(splitSubject(":is(#a, .b)")).toBeUndefined();
    // A complex argument matches differently once concatenated.
    expect(splitSubject(".p :is(.a .b, .c .d)")).toBeUndefined();
    // Functional, vendor and unknown pseudos: the forgiving list may be forgiving them.
    expect(splitSubject(":is(.a:not(.x), .b:not(.y))")).toBeUndefined();
    expect(splitSubject(":is(.a:-moz-focusring, .b:hover)")).toBeUndefined();
    expect(splitSubject(":is(.a::before, .b::before)")).toBeUndefined();
    // `:where` has zero specificity; nesting and an :is not at the subject's start.
    expect(splitSubject(":where(.a, .b)")).toBeUndefined();
    expect(splitSubject("& :is(.a, .b)")).toBeUndefined();
    expect(splitSubject(":is(.a, .b) .c")).toBeUndefined();
    expect(splitSubject(".c:is(.a, .b)")).toBeUndefined();
    expect(splitSubject(":is(.a)")).toBeUndefined();
  });

  test("specificity of a plain compound", () => {
    expect(plainSpecificity("button.x:hover")).toBe("0,2,1");
    expect(plainSpecificity("[data-on]")).toBe("0,1,0");
    expect(plainSpecificity("*")).toBe("0,0,0");
    expect(plainSpecificity('[data-focus-ring="row"]')).toBe("0,1,0");
    expect(plainSpecificity('[data-x="a b"]')).toBeUndefined();
    expect(plainSpecificity("[data-x=a]:hover")).toBe("0,2,0");
  });

  test("a rule keeps its place and declarations; a split list with a :has still splits per rule", () => {
    const root = postcss([splitSubjectIs(), splitHasLists()]).process(
      ".z { color: blue } .p :is(.a, .b) { color: red } :is(.h, .k):has(.x), .r { opacity: 1 }",
      { from: undefined },
    ).root;
    expect(root.nodes.map((node) => (node as postcss.Rule).selector)).toEqual([
      ".z",
      ".p .a, .p .b",
      ".h:has(.x)",
      ".k:has(.x)",
      ".r",
    ]);
  });

  test("the minifier does not wrap the split list back", () => {
    expect(selectors(built(".p :is(.a, .b):hover { color: red }", undefined))).toEqual([".p .a:hover", ".p .b:hover"]);
  });

  test("no stylesheet under src ships a subject :is it could split", () => {
    const found: string[] = [];
    for (const file of new Glob("src/**/*.css").scanSync({ cwd: webviews })) {
      const from = path.join(webviews, file);
      for (const selector of selectors(built(readFileSync(from, "utf8"), from)))
        if (splitSubject(selector)) found.push(`${file}: ${selector.slice(0, 160)}`);
    }
    expect(found).toEqual([]);
  });
});
