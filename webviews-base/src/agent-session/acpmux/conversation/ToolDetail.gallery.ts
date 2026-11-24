// l10n-allow-file: gallery fixtures, not shipped UI.
// An opened generic or MCP tool call as Claude's tool sheet draws it (Leo, 2026-11-05: "I saw this
// format for a tool call a session did idk if we also wanna model like that"; references
// claude/live/transcript-tool-call-card-input-output and claude-mobile/live/transcript-bash-tool-detail):
// Input as one card with a labeled field per argument, then Output with its copy button. The closed
// row stays one line. Two alternatives are drawn beside the selected card for comparison.
import type { Play } from "../../../gallery/play";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const START_INPUT = {
  title: "Hydration warning on the landing page",
  prompt:
    "## Goal\n\nFind why the landing page logs a hydration warning in production.\n\n- Read `app/page.tsx` and its layout\n- Compare the server and client renders\n- Propose the smallest fix",
  cwd: "~/src/storefront",
  harness: "claude",
  worktree: true,
};
const START_OUTPUT =
  "Nothing was proposed. The user is working over Remote Control and may not see a session card, so do not mention a card or suggest a session on this turn; carry on with what you were doing.";

const startSession = () =>
  tool("Start session", "other", "completed", {
    inputSummary: JSON.stringify(START_INPUT),
    output: START_OUTPUT,
  });

const createIssue = () =>
  tool("mcp__linear__create_issue", "other", "completed", {
    inputSummary: JSON.stringify({
      team: "WEB",
      title: "Landing page hydration warning",
      body: "The server renders the date in UTC and the client in local time, so the first paint differs.",
      labels: ["bug", "frontend"],
      priority: 2,
    }),
    output: JSON.stringify({
      content: [
        {
          type: "text",
          text: "Created **WEB-412** Landing page hydration warning\n\nhttps://linear.app/storefront/issue/WEB-412",
        },
      ],
    }),
  });

const openFirst: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("button.cv-tool"));
  ctx.document.querySelector<HTMLButtonElement>("button.cv-tool")?.click();
  // The opened body: the fields here, the output or request a build before them draws.
  await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-detail__field, .cv-mcp-call, .cv-tool-output-card"));
};

const restyled =
  (css: string): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = css;
    ctx.document.head.append(style);
    await openFirst(ctx);
  };

const generic = chat([
  user("Look into the hydration warning in a separate session", 3),
  activity([startSession()], 2),
  assistant("I'll keep going here instead.", 1),
]);
const mcp = chat([
  user("File an issue for the hydration warning", 3),
  activity([createIssue()], 2),
  assistant("Filed WEB-412.", 1),
]);

export default agentPaneEntry({
  id: "agent-pane.tool-detail",
  title: "Tool call detail: Input fields and Output",
  area: "Agent pane",
  height: 720,
  covers: [
    "agent-session/acpmux/conversation/ToolDetail.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/McpCallRows.tsx",
  ],
  variants: {
    closed: {
      note: "Closed, each call stays one transcript row; a click or tap opens it.",
      snapshot: chat([
        user("File an issue, then look into it in a session", 3),
        activity([createIssue()], 2),
        activity([startSession()], 2),
      ]),
    },
    generic: {
      note: "Selected: an opened generic call. One card holds a labeled field per argument (key small and monospace, value as prose; the prompt as Markdown; a flag as a value), then Output with a copy button on its heading.",
      snapshot: generic,
      play: openFirst,
    },
    mcp: {
      note: "Selected: an opened MCP call. Its machine name stays first, its arguments are fields (the list as a small tree), its response is the usual output card, and Raw keeps the request as it came.",
      snapshot: mcp,
      play: openFirst,
    },
    "flat-fields": {
      note: "Alternative: fields without the card, spaced instead of divided. Reads lighter but the Input part loses its edge against the transcript.",
      snapshot: generic,
      play: restyled(
        ".cv-tool-detail__fields { background: none; box-shadow: none; gap: 8px; } .cv-tool-detail__field { padding: 0 2px; } .cv-tool-detail__field + .cv-tool-detail__field { border-top: 0; }",
      ),
    },
    "side-keys": {
      note: "Alternative: keys in a left column, as a property list. Dense on a wide pane, but a long key squeezes its value and it wraps badly on a phone.",
      snapshot: generic,
      play: restyled(
        ".cv-tool-detail__field { grid-template-columns: 96px minmax(0, 1fr); column-gap: 12px; align-items: baseline; }",
      ),
    },
  },
});
