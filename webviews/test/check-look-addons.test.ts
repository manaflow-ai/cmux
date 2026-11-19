// Looks on public surfaces only (scripts/check-look-addons.ts): the repo's contract and add-ons pass;
// a look that styles a class, sets an internal variable or loads a file fails, and so does a contract
// token the host pushes inline or a stylesheet declares below the root.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  CONTRACT_PATH,
  checkAddonCss,
  checkContract,
  checkLooks,
  declarations,
  hostPushed,
  rootLevel,
  run,
  themeDerived,
  type Contract,
} from "../scripts/check-look-addons";

const contract = JSON.parse(readFileSync(CONTRACT_PATH, "utf8")) as Contract;
const kinds = (css: string) => checkAddonCss("look.css", css, contract).map((problem) => problem.kind);

test("the repo's contract and every look add-on pass", () => {
  expect(run()).toEqual([]);
});

test("a look sets contract tokens on :root, and nothing else", () => {
  expect(kinds(":root { --cv-user-bubble-radius: 6px; --cv-link: var(--agent-accent); }")).toEqual([]);
  expect(
    kinds(
      "@media (prefers-contrast: more) { :root { --cv-link: color-mix(in srgb, var(--agent-accent) 80%, var(--agent-text)); } }",
    ),
  ).toEqual([]);
  expect(kinds(".cv-user__bubble { --cv-user-bubble-radius: 6px; }")).toEqual(["selector"]);
  expect(kinds(":root { --cv-font-size: 13px; }")).toEqual(["private-token"]);
  expect(kinds(":root { color: red; }")).toEqual(["private-token"]);
  expect(kinds('@import "x.css"; :root { --cv-link: var(--agent-accent); }')).toContain("remote");
});

test("a look's colors come from the theme's, so it reads in light and dark", () => {
  // Studio 1.0.0's bubble and Paper 1.0.0's bubble: right for one appearance only (cmux#46049).
  expect(kinds(":root { --cv-user-bubble-tint: rgb(39 39 42 / 0.72); }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-text-muted: #6b6257; }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-link: steelblue; }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-link: color-mix(in srgb, #8a5a2b 50%, var(--agent-text)); }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-card-fill: oklch(0.9 0.02 80); }")).toEqual(["literal-color"]);
  expect(themeDerived(" color-mix(in oklch, var(--agent-accent) 9%, transparent)")).toBe(true);
  expect(themeDerived(" color-mix(in srgb, var(--agent-text) 72%, var(--agent-accent))")).toBe(true);
  expect(themeDerived(" transparent")).toBe(true);
  // A length is not a color: the corner keeps its px.
  expect(kinds(":root { --cv-user-bubble-radius: 18px; }")).toEqual([]);
});

test("declarations carry their selector chain", () => {
  expect(declarations("/* --x: 1 */ :root { --a: 1; } @media (x) { .b { --c: 2 } }")).toEqual([
    { name: "--a", selectors: [":root"] },
    { name: "--c", selectors: ["@media (x)", ".b"] },
  ]);
  expect(rootLevel([":root"])).toBe(true);
  expect(rootLevel(["@media (prefers-contrast: more)", ':root:not([data-borders="none"])'])).toBe(true);
  expect(rootLevel([".cv-user__bubble"])).toBe(false);
});

test("a contract token the host pushes, declares below the root, or nobody reads fails", () => {
  const token = { name: "--cv-x", kind: "color", owner: "a.css", about: "" };
  const one = (css: string, pushed = new Set<string>()) =>
    checkContract({ ...contract, tokens: [token] }, new Map([["a.css", css]]), pushed).map((p) => p.kind);
  expect(one(":root { --cv-x: red; } .y { color: var(--cv-x); }")).toEqual([]);
  expect(one(".y { --cv-x: red; color: var(--cv-x); }")).toEqual(["undeclared", "scoped"]);
  expect(one(":root { --cv-x: red; }")).toEqual(["unused"]);
  // A token with no value of its own: read with today's value as the fallback, declared nowhere.
  expect(one(".y { color: var(--cv-x, red); }")).toEqual([]);
  expect(one(".y { color: var(--cv-x); }")).toEqual(["undeclared"]);
  expect(one(":root { --cv-x: red; } .y { color: var(--cv-x); }", new Set(["--cv-x"]))).toEqual(["host-pushed"]);
  expect(hostPushed('const v = { text: "--agent-text" }; set(`--agent-ansi-${i}`)')).toEqual(
    new Set(["--agent-text", "--agent-ansi-*"]),
  );
});

test("every built-in look needs an add-on twin or a pending reason", () => {
  expect(checkLooks([], ["studio"], contract).map((p) => p.kind)).toEqual(["no-twin"]);
  expect(checkLooks([{ id: "studio", addon: null, builtIn: null }], ["studio"], contract).map((p) => p.kind)).toEqual([
    "no-twin",
  ]);
  expect(checkLooks([{ id: "studio", addon: null, builtIn: null, pending: "soon" }], ["studio"], contract)).toEqual([]);
});

test("the chat-pane groups: a reply card, hover timing, popovers and code colors", () => {
  expect(
    kinds(
      ":root { --cv-reply-fill: color-mix(in srgb, var(--agent-text) 4%, transparent); --cv-reply-ring: transparent; --cv-reply-radius: 10px; --cv-reply-padding: 10px; }",
    ),
  ).toEqual([]);
  expect(kinds(":root { --cv-hover-duration: 120ms; --cv-hover-ease: cubic-bezier(0, 0, 0.58, 1); }")).toEqual([]);
  expect(
    kinds(
      ":root { --cv-popover-fill: color-mix(in srgb, var(--agent-page-bg) 80%, transparent); --cv-popover-ring: var(--agent-border); --cv-popover-radius: 12px; --cv-popover-row-selected: color-mix(in srgb, var(--agent-accent) 28%, transparent); }",
    ),
  ).toEqual([]);
  expect(kinds(":root { --cv-code-keyword: var(--agent-ansi-5); --cv-code-comment: var(--agent-soft); }")).toEqual([]);
  // Their colors follow the theme like every other color token's.
  expect(kinds(":root { --cv-reply-fill: #1d1d1f; }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-code-string: rgb(120 200 80); }")).toEqual(["literal-color"]);
  // A press scale is not a token: a held button changes only its fill (design/pressed-state.md).
  expect(kinds(":root { --cv-press-scale: 0.96; }")).toEqual(["private-token"]);
});

test("a script owner names its token as a string literal and declares nothing", () => {
  const token = { name: "--cv-code-x", kind: "color", owner: "a.ts", about: "" };
  const one = (source: string, css = "") =>
    checkContract(
      { ...contract, tokens: [token] },
      new Map([["b.css", css]]),
      new Set<string>(),
      new Map([["a.ts", source]]),
    ).map((p) => p.kind);
  expect(one('const tokens = { x: "--cv-code-x" };')).toEqual([]);
  expect(one("const tokens = {};")).toEqual(["undeclared", "unused"]);
  // Declared below the root in a stylesheet, its value would stop there.
  expect(one('const tokens = { x: "--cv-code-x" };', ".y { --cv-code-x: red; }")).toEqual([
    "undeclared",
    "scoped",
    "unused",
  ]);
});
