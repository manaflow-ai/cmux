// The "·" between a worked or live line's label and its counts (Thinking.tsx, WorkingFor.tsx,
// TurnRows.tsx) sits as far from what comes before it as from what follows it. The line is a flex
// row with the grid gap between its items, and the count's own margin added to that gap had left
// 10px before the dot and 4px after it (Leo, 2026-11-04, on "2s · 15s total": "same here it's
// annoying to look at").
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);
const rules = [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({
  selectors: selector!.split(",").map((part) => part.trim()),
  body: body!.replace(/\s+/g, ""),
}));
const declared = (selector: string, property: string) =>
  rules
    .filter((rule) => rule.selectors.includes(selector))
    .flatMap((rule) => rule.body.split(";").filter((decl) => decl.startsWith(`${property}:`)))
    .map((decl) => decl.slice(property.length + 1));

test("the line's counts take back its grid gap, so the dot has 4px on each side", () => {
  expect(declared(".cv-worked", "gap")).toEqual(["var(--grid-gap)"]);
  expect(declared(".cv-worked__count", "gap")).toEqual(["4px"]);
  expect(declared(".cv-worked__count", "margin-left")).toEqual(["calc(4px-var(--grid-gap))"]);
});
