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
  motionDuration,
  motionEasing,
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
  // light-dark() over the theme's own follows the appearance; over literals it is two literals.
  expect(themeDerived(" light-dark(var(--agent-page-bg), var(--agent-text))")).toBe(true);
  expect(themeDerived(" light-dark(white, black)")).toBe(false);
  expect(themeDerived(" light-dark(#fff, var(--agent-text))")).toBe(false);
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

test("a look sets the chat's motion within bounds, and animations off and Reduce Motion still win", () => {
  expect(kinds(":root { --cmux-motion-micro: 150ms; --cmux-ease-out: cubic-bezier(0.4, 0, 0.2, 1); }")).toEqual([]);
  expect(
    kinds(":root { --cmux-motion-large: 0.3s; --cmux-motion-send: 0; --cmux-ease-spring: linear(0, 0.6 30%, 1); }"),
  ).toEqual([]);
  expect(
    kinds(":root { --cmux-ease-settle: var(--cmux-ease-out); --cmux-motion-settle: var(--cmux-motion-large); }"),
  ).toEqual([]);
  expect(kinds(":root { --cmux-motion-quick: 900ms; }")).toEqual(["motion-bounds"]);
  expect(kinds(":root { --cmux-motion-quick: -1ms; }")).toEqual(["motion-bounds"]);
  expect(kinds(":root { --cmux-motion-quick: 150ms !important; }")).toEqual(["motion-bounds"]);
  expect(kinds(":root { --cmux-ease-out: cubic-bezier(1.4, 0, 0.2, 1); }")).toEqual(["motion-bounds"]);
  expect(kinds(":root { --cmux-ease-out: steps(4); }")).toEqual(["motion-bounds"]);
  expect(kinds(":root { --cmux-ease-out: ease-in-out; }")).toEqual(["motion-bounds"]);
  // The scale's other tokens stay private.
  expect(kinds(":root { --cmux-motion-send-pop: 100ms; --cmux-spinner-period: 1s; }")).toEqual([
    "private-token",
    "private-token",
  ]);
  expect(motionDuration("600ms")).toBe(true);
  expect(motionDuration("601ms")).toBe(false);
  expect(motionEasing("cubic-bezier(0.34, 1.3, 0.64, 1)")).toBe(true);
  // The off and reduced roots put cmux's own values back, above a look's plain :root, in each
  // motion token's owner stylesheet (the scale's in desktop.css, the arrival step in conversation.css).
  const restoreIn = (owner: string) =>
    declarations(readFileSync(new URL(`../../${owner}`, import.meta.url), "utf8")).filter((decl) =>
      decl.selectors.some((sel) => sel.includes('data-cmux-motion="reduced"')),
    );
  for (const token of contract.tokens.filter((t) => t.kind === "duration" || t.kind === "easing")) {
    const restore = restoreIn(token.owner).filter((decl) => decl.name === token.name);
    expect(restore.map((decl) => decl.name)).toContain(token.name);
    for (const sel of ['data-agent-motion="off"', 'data-agent-motion="reduced"', 'data-cmux-motion="off"'])
      expect(restore[0]!.selectors.join(",")).toContain(sel);
  }
});
