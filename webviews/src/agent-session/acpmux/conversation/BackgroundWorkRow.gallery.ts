// l10n-allow-file: gallery fixtures (sample prompts, commands and chat titles), not shipped UI.
// The transcript's last row while background work outlives its turn (BackgroundWorkRow.tsx):
// "Running in background · 1 command · 2 sessions", from a background Bash call that has not
// ended and two chats the agent started that still run. A click opens the summary card.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, session, SESSION_ID, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";

const devServer = tool("bun run dev --port 5173", "execute", "completed", {
  command: "bun run dev --port 5173",
  inputSummary: JSON.stringify({ command: "bun run dev --port 5173", run_in_background: true }),
  startedAt: minutesAgo(6),
});

const snapshot = () => {
  const base = chat([
    user("Start the dev server, then split the migration into two chats", 7),
    activity([devServer], 6),
    assistant("The dev server runs on :5173, and two chats are migrating the settings store and the history page.", 5),
    summary(5, { status: "completed", durationMs: 70_000, toolCount: 1 }),
  ]);
  return {
    ...base,
    sessions: [
      ...base.sessions,
      session({
        sessionId: "child-1",
        title: "Migrate the settings store to SQLite",
        spawnedBy: SESSION_ID,
        indicator: "working",
        status: "running",
        createdAt: minutesAgo(5.5),
      }),
      session({
        sessionId: "child-2",
        title: "Port the history page to React Aria",
        spawnedBy: SESSION_ID,
        indicator: "working",
        status: "running",
        createdAt: minutesAgo(5.4),
      }),
    ],
  };
};

export default agentPaneEntry({
  id: "agent-pane.background-work-row",
  title: "Running in background row",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/BackgroundWorkRow.tsx#BackgroundWorkLine"],
  variants: {
    running: {
      note: "After the turn: a background command and two started chats still run, as one row at the transcript's end.",
      snapshot: snapshot(),
    },
    "opens-summary": {
      note: "A click on the row opens the summary card, which lists the command with Stop and the chats under Subagents.",
      snapshot: snapshot(),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-bgwork" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-session"));
      },
    },
  },
});
