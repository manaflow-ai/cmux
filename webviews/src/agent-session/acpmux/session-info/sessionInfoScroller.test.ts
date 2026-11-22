import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "sessionInfo.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

/** Every declaration block whose selector list names the Session Info body (not a descendant of it). */
function bodyRules(pseudo = ""): string[] {
  const out: string[] = [];
  for (const match of css.matchAll(/([^{}]+)\{([^}]*)\}/g)) {
    const selectors = match[1]!.split(",").map((s) => s.trim());
    if (selectors.some((s) => new RegExp(`^\\.acpmux-session-info__body${pseudo}$`).test(s))) out.push(match[2]!);
  }
  return out;
}

// Leo, 2026-11-03: "i mean there's literally no scrollbar in claude code it's just scrollable".
test("the Session Info body scrolls with no scrollbar and keeps no width for one", () => {
  const body = bodyRules().join(";");
  expect(body).toMatch(/overflow-y:\s*auto/);
  expect(body).toMatch(/scrollbar-width:\s*none/);
  expect(bodyRules("::-webkit-scrollbar").join(";")).toMatch(/display:\s*none/);
  expect(css).not.toMatch(/\.acpmux-session-info__body[^{]*\{[^}]*scrollbar-gutter/);
  expect(css).not.toMatch(/\.acpmux-session-info__body[^{]*::-webkit-scrollbar-thumb/);
});
