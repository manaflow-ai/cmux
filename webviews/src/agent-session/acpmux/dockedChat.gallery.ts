// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The agent chat in the left chat dock (a dock column with the agent_chat role,
// plans/cmux-next/dock-column.md): the whole pane at the dock's widths. A dock takes 25-40% of
// the content area, so these widths are that share of a 1200 px window, not the pane presets.
import { agentPaneEntry } from "../../gallery/format";
import { activity, assistant, chat, CWD, noChat, session, summary, tool, user } from "../../gallery/fixtures/acpmux";

const turn = [
  user("Add retries with backoff to the fetch helper", 12),
  activity(
    [
      tool("Read src/net/client.ts", "read", "completed"),
      tool("Edit src/net/retry.ts", "edit", "completed"),
      tool("bun test src/net", "execute", "completed"),
    ],
    11,
  ),
  assistant("Done: GETs retry three times with jittered backoff; POSTs retry only with a policy.", 10),
  summary(10, { status: "completed" }),
];

const PROMPT = "[contenteditable='true']";
const draftShown = (doc: Document) => doc.querySelector(PROMPT)?.textContent?.includes("POST") ?? false;

export default agentPaneEntry({
  id: "agent-pane.docked-chat",
  title: "Docked chat",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 300, normal: 400, wide: 480 },
  anchors: [{ selector: ".acpmux-scroll" }],
  checks: {
    anchorMovePx: {
      value: 128,
      reason: "Typing a wrapping dock draft intentionally grows the composer and resizes the transcript viewport.",
    },
    layoutShiftMax: {
      value: 0.05,
      reason: "The dock composer grows in flow while the typed draft wraps, producing a bounded layout shift.",
    },
  },
  covers: ["page:cmux.agent", "agent-session/acpmux/App.tsx#AcpmuxApp"],
  variants: {
    "new-chat": {
      note: "A new chat in the dock: empty prompt and the location row at dock width.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
    },
    "after-turn": {
      note: "A finished turn with tool rows: the transcript and chips wrap at dock width.",
      snapshot: chat(turn),
    },
    working: {
      note: "A turn running in the dock: Stop replaces Send.",
      snapshot: chat([user("Run the net tests", 1), assistant("Running bun test src/net…", 0.5, { streaming: true })], {
        isWorking: true,
      }),
    },
    "typing-in-dock": {
      note: "A two-line draft typed at dock width: the composer grows and the transcript viewport resizes.",
      snapshot: chat(turn),
      play: async (ctx) => {
        await ctx.click({ selector: PROMPT });
        await ctx.type("Also add a circuit breaker after five failures, and keep the POST rule as it is.");
        await ctx.waitFor(() => draftShown(ctx.document));
      },
    },
    "long-title": {
      note: "A long chat title and model name in the dock's header.",
      snapshot: chat(turn, {
        title: "Retry the fetch helper with jittered exponential backoff and a POST policy",
        model: "claude-opus-5-5",
      }),
    },
  },
});
