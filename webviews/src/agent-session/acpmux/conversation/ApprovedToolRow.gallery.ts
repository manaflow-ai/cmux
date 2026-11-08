// l10n-allow-file: gallery fixtures (sample commands), not shipped UI.
// An approved permission ask reads on the call it approved: "Approved" at the row's edge, before its
// check and time, never a loose "Approved: <command> (Bypass permissions)" line holding the raw
// command cut off mid-quote (Leo, 2026-11-02: "but what's going on with these?"). An approval the
// chat's Bypass permissions or Full access gave on its own draws nothing (direct.ts
// `recordFullAccess`); a denied or unanswered ask keeps its receipt line.
// test/agent-pane-permission-receipt.test.ts drives the same rows from acpmux records.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";

const ISSUES =
  "cd /tmp; for i in 1 2 3; do gh issue create --repo manaflow-ai/cmux --title \"$( [ $i = 1 ] && echo 'Cloud start-session: no machine' )\"; done";

const run = (description: string, command: string, approved?: true): AcpmuxActivity =>
  tool(command, "execute", "completed", {
    description,
    command,
    output: "ok\n",
    exitCode: 0,
    ...(approved && { approved }),
  });

const snapshot = (items: AcpmuxActivity[]) => {
  const base = chat(
    [
      user("File the three Cloud start-session issues.", 6),
      activity(items, 5.9),
      assistant("Filed all three.", 5),
      summary(5, { status: "completed", durationMs: 42_000 }),
    ],
    { title: "cloud-issues" },
  );
  return { ...base, summary: { ...base.summary!, family: "claude" } };
};

/// Opens the turn's work, so its rows show.
const openWork: Play = async (ctx) => {
  const fold = () =>
    [...ctx.document.querySelectorAll<HTMLButtonElement>("button[aria-expanded='false']")].find((node) =>
      /Worked for|Ran \d/.test(node.textContent ?? ""),
    );
  await ctx.waitFor(() => ctx.document.querySelector(".cv-tool"), { capMs: 10_000 });
  for (let i = 0; i < 3 && fold(); i++) fold()!.click();
};

export default agentPaneEntry({
  id: "agent-pane.approved-tool-row",
  title: "Approved permission asks read on their tool row, never as a line of their own",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/conversation/ApprovedMark.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/McpCallRows.tsx",
  ],
  variants: {
    "ask-mode-approved": {
      note: 'Manual mode: the person allowed the Bash call; its row says "Approved" at the edge, dim, before the check and time.',
      snapshot: snapshot([run("File the three Cloud issues", ISSUES, true)]),
      play: openWork,
    },
    "run-one-approved": {
      note: 'A run of commands where only the middle one asked: only that row carries "Approved".',
      snapshot: snapshot([
        run("List open Cloud issues", "gh issue list --repo manaflow-ai/cmux -l cloud"),
        run("File the three Cloud issues", ISSUES, true),
        run("Check they filed", "gh issue list --repo manaflow-ai/cmux -l cloud -L 3"),
      ]),
      play: openWork,
    },
    "mcp-approved": {
      note: 'An MCP call the person allowed: its row says "Approved" at the edge too.',
      snapshot: snapshot([
        tool("mcp__github__create_issue", "other", "completed", {
          output: '{"number": 33410}',
          inputSummary: JSON.stringify({ repo: "manaflow-ai/cmux", title: "Cloud start-session: no machine" }),
          approved: true,
        }),
      ]),
      play: openWork,
    },
    "bypass-nothing": {
      note: "Bypass permissions: Claude Code's own guard was approved by the mode; nothing marks the row and no receipt line is drawn.",
      snapshot: snapshot([run("File the three Cloud issues", ISSUES)]),
      play: openWork,
    },
  },
});
