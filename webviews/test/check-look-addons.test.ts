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
  type Contract,
} from "../scripts/check-look-addons";

const contract = JSON.parse(readFileSync(CONTRACT_PATH, "utf8")) as Contract;
const kinds = (css: string) => checkAddonCss("look.css", css, contract).map((problem) => problem.kind);

test("the repo's contract and every look add-on pass", () => {
  expect(run()).toEqual([]);
});

test("a look sets contract tokens on :root, and nothing else", () => {
  expect(kinds(":root { --cv-user-bubble-radius: 6px; --cv-link: var(--agent-accent); }")).toEqual([]);
  expect(kinds(".cv-user__bubble { --cv-user-bubble-radius: 6px; }")).toEqual(["selector"]);
  expect(kinds(":root { --cv-font-size: 13px; }")).toEqual(["private-token"]);
  expect(kinds(":root { color: red; }")).toEqual(["private-token"]);
  expect(kinds('@import "x.css"; :root { --cv-link: var(--agent-accent); }')).toContain("remote");
});

test("a look's colors are the theme's own, so it reads in light and dark", () => {
  // Studio's #46049 values: 2.9:1 on a light theme, and Paper's white-on-beige 1.4:1 on a dark one.
  expect(kinds(":root { --cv-link: #93c5fd; }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-card-fill: rgb(244 239 229 / 0.9); }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-link: red; }")).toEqual(["literal-color"]);
  expect(kinds(":root { --cv-link: var(--cv-private-blue); }")).toEqual(["literal-color"]);
  expect(kinds("@media (prefers-color-scheme: light) { :root { --cv-link: #0b63d6; } }")).toEqual(["literal-color"]);
  expect(
    kinds(
      ":root { --cv-card-fill: color-mix(in srgb, var(--agent-text) 4%, transparent); --cv-text-dim: var(--cv-text-muted); }",
    ),
  ).toEqual([]);
  // A length is no color: a corner may be any length.
  expect(kinds(":root { --cv-user-bubble-radius: calc(2px + 0.5em); }")).toEqual([]);
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
