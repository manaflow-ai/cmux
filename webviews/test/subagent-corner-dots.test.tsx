// l10n-allow-file: test fixture subagent names and states, not shipped UI.
// No status dot on the corner of a subagent's icon or avatar (Leo 2026-10-22: "the bottom right
// dots in most situations is kinda weird and unnecsesary... e.g. projects in teh new tab projects
// selection, then the subagnets running... it doenst really tell me much"). Every row that drew one
// already says the state in words beside it: the tray's and the summary's lines (AgentLine), the
// started chats (ChildSessionRows), the sub-sessions (SubagentStatusList) and an open group's rows
// (SubagentListRow, whose line is the state or what a running one does now, with its Stop). The
// project picker's corner dot went in #24310 (ProjectBadge.test.tsx pins it).
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { AgentLine } from "../src/agent-session/acpmux/subagents/AgentLine";
import { SubagentListRow } from "../src/agent-session/acpmux/subagents/SubagentGroup";
import type { SubagentStatus } from "../src/agent-session/acpmux/summary/SubagentStatusList";

const src = path.resolve(import.meta.dir, "../src");

/// Every stylesheet the webviews ship, with comments stripped, as [file, css].
function stylesheets(dir: string): [string, string][] {
  return readdirSync(dir, { withFileTypes: true, recursive: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".css"))
    .map((entry) => {
      const file = path.join(entry.parentPath, entry.name);
      return [path.relative(src, file), readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "")];
    });
}

/// The selectors of every rule in `css`.
const selectors = (css: string) => [...css.matchAll(/([^{}]+)\{[^{}]*\}/g)].map((match) => match[1]!.trim());

test("no stylesheet draws a dot on a subagent icon's or avatar's corner", () => {
  const found = stylesheets(src).flatMap(([file, css]) =>
    selectors(css)
      .filter(
        (selector) =>
          /\.acpmux-lineage__icon[^,]*::?(?:after|before)/.test(selector) ||
          selector.includes("cv-subagent-avatar__dot"),
      )
      .map((selector) => `${file}: ${selector}`),
  );
  expect(found).toEqual([]);
});

test("a subagent line says its state in words and draws no dot", () => {
  const states: [SubagentStatus, string][] = [
    ["running", "Running"],
    ["waiting", "Waiting"],
    ["done", "Done"],
    ["failed", "Failed"],
  ];
  for (const [status, word] of states) {
    const html = renderToStaticMarkup(<AgentLine name="Check the docs" status={status} state={word} time="1m" />);
    expect(html).toContain(`>${word}</span>`);
    expect(html).not.toMatch(/class="[^"]*dot[^"]*"/);
  }
});

test("an open group's subagent row has no dot on its avatar", () => {
  for (const state of ["running", "completed", "failed"]) {
    const row = {
      id: `group:${state}`,
      kind: "subagent",
      subagents: [{ id: `agent-${state}`, parent: null, name: "Retry policy", state, startedAt: 0, endedAt: 60_000 }],
    } as unknown as AcpmuxRow;
    const html = renderToStaticMarkup(<SubagentListRow row={row} />);
    expect(html).toContain('class="cv-subagent-avatar"');
    expect(html).not.toContain("cv-subagent-avatar__dot");
  }
});
