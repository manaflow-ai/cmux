import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("./prototype.css", import.meta.url), "utf8");

function rule(selector: string): string {
  const start = css.indexOf(`${selector} {`);
  expect(start).toBeGreaterThanOrEqual(0);
  const end = css.indexOf("}", start);
  expect(end).toBeGreaterThan(start);
  return css.slice(start, end);
}

test("tab close is a trailing overlay, so hidden x controls do not reserve label width", () => {
  expect(rule(".proto-tab")).toMatch(/position:\s*relative/);
  const close = rule(".proto-tab-close");
  expect(close).toMatch(/position:\s*absolute/);
  expect(close).toMatch(/inset-inline-end:\s*3px/);
  expect(close).toMatch(/top:\s*2px/);
  expect(close).not.toMatch(/margin-right/);
});

test("tab close keeps pointer hover and keyboard focus reveal behavior", () => {
  expect(css).toMatch(/\.proto-tab:hover \.proto-tab-close,/);
  expect(css).toMatch(/\.proto-tab:focus-within \.proto-tab-close,/);
  expect(css).toMatch(/\.proto-tab-close:focus-visible\s*\{/);
  expect(rule(".proto-tab-close")).toMatch(/opacity:\s*0/);
});
