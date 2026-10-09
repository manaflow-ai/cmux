// l10n-allow-file: gallery fixtures (sample chats and connection errors), not shipped UI.
// The pane header (ChatHeaderStatus.tsx): no title; a status shows only for a connection problem, with the
// failure detail as its tooltip (focusable from the keyboard). A retry warns; a lost or failed connection is an error.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

export default agentPaneEntry({
  id: "agent-pane.header",
  title: "Header",
  area: "Agent pane",
  height: 320,
  covers: ["agent-session/acpmux/header/ChatHeaderStatus.tsx#ChatHeaderStatus"],
  variants: {
    quiet: {
      note: "Connected after a turn: no title, no status; Changes shows the last turn's counts when the pane is wide enough.",
      snapshot: chat(finished),
    },
    disconnected: {
      note: "The daemon connection dropped.",
      snapshot: chat(finished, { connection: "disconnected" }),
    },
    reconnecting: {
      note: "Retrying after a failure; the failure is the tooltip.",
      snapshot: chat(finished, { connection: "connecting: connection refused by the local daemon" }),
    },
    "failed-hover": {
      note: "Round 1: the failure detail is the tooltip and the accessible label; hovering shows it.",
      snapshot: chat(finished, {
        connection: "error: the agent process exited with status 1 before it answered the initialize request",
      }),
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-status" });
      },
    },
    failed: {
      note: "A long failure detail must not move the header tools.",
      snapshot: chat(finished, {
        connection:
          "error: the agent process exited with status 1 before it answered the initialize request; see the agent log",
      }),
    },
  },
});
