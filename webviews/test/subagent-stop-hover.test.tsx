// l10n-allow-file: test fixture subagent names, not shipped UI.
// A running subagent's Stop in the transcript shows only on its own row's hover or focus, at once
// with no fade, so a group of running agents does not repeat a lit Stop on every row (Leo: a
// design that repeats a control on every row is a BLOCK). It stays in the DOM with its label, so
// Tab and assistive tech still reach it.
import { readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { setPaneLanguage } from "../src/agent-session/acpmux/i18n";
import { SubagentListRow, SubagentStopContext } from "../src/agent-session/acpmux/subagents/SubagentGroup";

const css = readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents/subagents.css"),
  "utf8",
).replace(/\/\*[\s\S]*?\*\//g, "");

function rules(): Array<{ selector: string; body: string }> {
  return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ selector: m[1]!.trim(), body: m[2]! }));
}

test("a row's Stop is transparent at rest, with no fade", () => {
  const rest = rules().find((rule) => rule.selector === ".cv-subagent-stoppable > .cv-subagent__stop");
  expect(rest?.body).toMatch(/opacity:\s*0;/);
  expect(rest?.body).toMatch(/transition:\s*none;/);
  expect(rest?.body).not.toMatch(/display:\s*none|visibility:\s*hidden/);
});

test("only its own row's hover or focus lights a row's Stop", () => {
  const lighting = rules().filter(
    (rule) =>
      rule.selector.includes(".cv-subagent-stoppable") &&
      rule.selector.includes(".cv-subagent__stop") &&
      /opacity:\s*(?!0;)[\d.]+/.test(rule.body),
  );
  expect(lighting.length).toBeGreaterThan(0);
  for (const rule of lighting)
    expect(rule.selector).toMatch(
      /^\.cv-subagent-stoppable:is\(:hover, :focus-within\) > \.cv-subagent__stop(:disabled)?$/,
    );
  // The row itself takes no highlight from the stoppable wrapper.
  for (const rule of rules().filter((r) => /\.cv-subagent-stoppable(:[^>\s]+)?$/.test(r.selector)))
    expect(rule.body).not.toMatch(/background/);
});

test("the hidden Stop stays in the DOM with its label", () => {
  setPaneLanguage("en");
  const row = {
    id: "subagent-a",
    kind: "subagent",
    status: "running",
    subagents: [{ id: "a", parent: null, name: "Watch the build", state: "running" }],
  } as unknown as AcpmuxRow;
  const html = renderToStaticMarkup(
    <SubagentStopContext.Provider value={async () => {}}>
      <SubagentListRow row={row} />
    </SubagentStopContext.Provider>,
  );
  expect(html).toContain('class="cv-subagent-stoppable"');
  expect(html).toMatch(/<button[^>]*class="cv-subagent__stop"[^>]*aria-label="Stop Watch the build"/);
});
