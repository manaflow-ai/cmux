// l10n-allow-file: gallery fixtures (sample chats and connection errors), not shipped UI.
// The pane header (ChatHeaderStatus.tsx): no title and no change counts; a status shows only
// for a connection problem, with the failure detail as its tooltip.
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
      note: "Connected after a turn: no title, no status, the Changes button is icon-only.",
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
    failed: {
      note: "A long failure detail must not move the header tools.",
      snapshot: chat(finished, {
        connection:
          "error: the agent process exited with status 1 before it answered the initialize request; see the agent log",
      }),
    },
  },
});
