// The Home inbox count (HomeInbox.tsx) keeps one rule: muted, tabular digits so the label does not
// shift when the count changes. #28486 added a second selector for it on the row meta rule, which
// duplicated that rule; this keeps the count's style in exactly one place.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");
const rules = [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({
  selectors: selector!.split(",").map((part) => part.trim()),
  body: body!,
}));

test("the Home inbox count is styled by one rule, with tabular digits", () => {
  const count = rules.filter((rule) => rule.selectors.some((selector) => /\.acpmux-home-inbox-count\b/.test(selector)));
  expect(count.map((rule) => rule.selectors.join(","))).toEqual([".acpmux-home-inbox-count"]);
  expect(count[0]!.body).toContain("font-variant-numeric:tabular-nums");
});

test("Home row ages keep tabular digits", () => {
  const meta = rules.find((rule) => rule.selectors.includes(".acpmux-home-meta"));
  expect(meta?.body).toContain("font-variant-numeric:tabular-nums");
});
