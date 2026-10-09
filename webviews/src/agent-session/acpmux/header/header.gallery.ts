// l10n-allow-file: gallery fixtures (sample chats and connection errors), not shipped UI.
// A quiet connected header; connection failures expose details on hover and keyboard focus.
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
      note: "Connected after a turn: no title or status; the summary carries its completion mark.",
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
          "error: Gateway returned 502 before initialize completed. https://gateway.example.com/agents/connections/retry/01J9K8BXSQ7M4TN6WV2F0EPD3A?source=local-daemon&attempt=12 — check the agent log for the full request trace.",
      }),
    },
    "failure-detail": {
      note: "Keyboard focus reveals the complete, wrapping failure in its own opaque layer.",
      snapshot: chat(finished, {
        connection:
          "error: Gateway returned 502. https://gateway.example.com/agents/connections/retry/01J9K8BXSQ7M4TN6WV2F0EPD3A?source=local-daemon&attempt=12",
      }),
    },
  },
});
