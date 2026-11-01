// Session Info → Environment lists each grant as a row with Revoke (#28617). A list of grants must not
// repeat a lit Revoke on every row: a grant's Revoke is transparent at rest (still reachable by Tab) and
// shows only while its own row is hovered or holds focus, at once with no fade. This pins sessionInfo.css
// to that, since a jsdom render cannot compute :hover.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/session-info/sessionInfo.css"), "utf8");

function block(selector: string): string {
  const at = css.indexOf(`${selector} {`);
  expect(at).toBeGreaterThanOrEqual(0);
  return css.slice(at, css.indexOf("}", at));
}

test("a grant's Revoke is transparent at rest, with no fade", () => {
  const rest = block(".acpmux-session-info-row--grant > .acpmux-session-info-link");
  expect(rest).toMatch(/opacity:\s*0;/);
  expect(rest).toMatch(/transition:\s*none;/);
});

test("only the hovered or focused grant row shows its own Revoke", () => {
  const shown = block(".acpmux-session-info-row--grant:is(:hover, :focus-within) > .acpmux-session-info-link");
  expect(shown).toMatch(/opacity:\s*1;/);
  // No other rule lights every grant's Revoke at once (a list-wide :hover, or the list itself).
  const lit = [...css.matchAll(/([^{}]*row--grant[^{}]*)\{[^}]*opacity:\s*1/g)].map((m) => m[1].trim());
  expect(lit).toEqual([".acpmux-session-info-row--grant:is(:hover, :focus-within) > .acpmux-session-info-link"]);
});
