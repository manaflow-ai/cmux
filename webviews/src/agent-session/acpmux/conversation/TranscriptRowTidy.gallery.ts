// l10n-allow-file: gallery fixtures (sample commands, lane names and messages), not shipped UI.
// One turn's rows as they stack (Leo, 2026-10-29: "Man, what the fuck is this spacing? Why is there
// space between ran and two? And why is one of these bold? And why is there space, a fucking gap in
// between them? And why do you have the fucking open chat? Nobody asked for open chat. We can just
// click. Just have the thing be clickable, and then you can open it."): a command, a group of two
// that reads "Ran 2 commands" with one space (ToolGroupRow.tsx), a started sub-session and another
// chat's message, both regular weight with no gap between them, each line its chat's button and its
// chevron the panel's toggle (subagents/DisclosureRow.tsx), with no "Open chat" word.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, session, tool, user, SESSION_ID } from "../../../gallery/fixtures/acpmux";

const command = (description: string, line: string) =>
  tool(description, "execute", "completed", {
    command: line,
    inputSummary: JSON.stringify({ command: line, description }),
  });

const start = (name: string, id: string) =>
  tool("mcp__cmux-subsessions__start_session", "other", "completed", {
    inputSummary: JSON.stringify({ name, model: "gpt-5-codex", harness: "codex", prompt: `Own the ${name} lane` }),
    output: `Started sub-session ${name} (sessionId ${id}, depth 1).`,
  });

const LINK = "link-check: the docs link to the release notes 404s; the fix is on docs/link-fix.";

const rows = [
  user("Check the release notes links and start a lane for the mesh.", 4),
  activity(
    [
      command("Forward the no-hold order to the release lane", "lane send release 'no hold'"),
      command("git status", "git status"),
      command("git diff --stat", "git diff --stat"),
      start("mesh", "sub-mesh"),
    ],
    3.8,
  ),
  user(LINK, 3.5, {
    incoming: {
      kind: "message" as const,
      message: { name: "link-check", text: LINK, raw: LINK, sessionId: "sub-link" },
    },
    untyped: true,
  }),
  assistant("Started mesh; link-check has a fix on docs/link-fix.", 3.2),
];

const base = chat(rows, { title: "Release notes links", isWorking: true });
const snapshot = {
  ...base,
  sessions: [
    ...base.sessions,
    session({
      sessionId: "sub-mesh",
      title: "Own the mesh lane",
      name: "mesh",
      shortName: "mesh",
      harness: "codex",
      model: "gpt-5-codex",
      startedBy: SESSION_ID,
      lane: "working",
      indicator: "working",
      status: "running",
    }),
    session({ sessionId: "sub-link", title: "Check the docs links", name: "link-check", shortName: "link-check" }),
  ],
};

/// The pointer on the sub-session's line: the line itself lights as the chat's button.
const hoverStart: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-disclosure__open") !== null);
  await ctx.hover({ selector: ".cv-disclosure__open" });
};

export default agentPaneEntry({
  id: "agent-pane.transcript-row-tidy",
  title: "Tool, sub-session and message rows, stacked",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
    "agent-session/acpmux/subagents/DisclosureRow.tsx",
    "agent-session/acpmux/subagents/AgentCard.tsx",
  ],
  variants: {
    rows: {
      note: '"Ran 2 commands" reads with one space; the started sub-session and the message under it are regular weight in the tool rows\' 26px lines with no gap between them, and neither has an Open chat word.',
      snapshot,
    },
    hover: {
      note: "The pointer on the sub-session's line: the line is its chat's button; the chevron after it alone opens the prompt.",
      snapshot,
      play: hoverStart,
    },
  },
});
