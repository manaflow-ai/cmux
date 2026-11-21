// l10n-allow-file: test fixtures (commands), not shipped UI.
// A background command shows as a normal tool row in its place, its words shimmering while it runs,
// as every running call does; no separate "1 background command running" line is drawn under the
// run's steps (Leo, 2026-11-06: "when it says one background command running, why doesn't it just
// show it normally like the other ones? Why does it have to say background?").
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { ToolGroupRow } from "../src/agent-session/acpmux/conversation/ToolGroupRow";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const shell = (id: string, command: string, extra: Partial<Tool> = {}): AcpmuxActivity => {
  const tool: Tool = { id, title: "Bash", kind: "execute", status: "completed", command, ...extra };
  return { kind: "tool", text: tool.title, tool };
};
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const run = [
  shell("bg-api", "bun run dev:api", { background: { state: "running" } }),
  shell("git", "git status --short"),
  shell("bg-migrate", "bun run migrate", { background: { state: "completed", endedAt: 2 } }),
];

test("a running background command is a normal row in the opened run, with no count line under it", () => {
  const html = renderToStaticMarkup(<ToolGroupRow kind="commands" items={run} disclosureKey="bg-inline" />);
  // No line that counts the background commands, in any wording.
  expect(html).not.toContain("cv-bgstatus");
  expect(text(html)).not.toMatch(/\d+ background commands? (running|completed|failed)/i);
  expect(text(html)).not.toMatch(/\d+ running/);
  // The command is a step of the run, a command row in its place among the others.
  const steps = [...html.matchAll(/<div class="cv-step[^"]*"[^>]*>\s*<button[^>]*data-tool-id="([^"]+)"/g)].map(
    (match) => match[1],
  );
  expect(steps).toEqual(["bg-api", "git", "bg-migrate"]);
  // While it runs, its row is live like any running call: its words shimmer, nothing names it background.
  const row = html.match(/<button[^>]*data-tool-id="bg-api"[^>]*>[\s\S]*?<\/button>/)?.[0] ?? "";
  expect(row).toMatch(/class="cv-tool cv-command is-toggle is-live"/);
  expect(row).toContain("bun run dev:api");
  expect(row).toContain("cv-row-shimmer");
  // The steps end on the last call's row: nothing is drawn after them, only the closing boxes (the
  // run's scroll box, RunScroll.tsx, among them).
  expect(html).toMatch(/bun run migrate[\s\S]*<\/button>(<\/div>)+$/);
});
