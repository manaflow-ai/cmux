// l10n-allow-file: gallery fixtures (sample chats and connection errors), not shipped UI.
// The pane header (ChatHeaderStatus.tsx): tools and connection failures only.
// Where a started chat runs is the Inspector's Environment; the header never repeats it.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

// The App offers the pane's tab row (chrome.tabs.rowTools, on by default): the status slot is under the
// tabs, so the warning leads the tools instead (ChatHeaderInlineStatus).
const inTabRow: Play = async (ctx) => {
  const { setTabRow } = await import("./tabRow");
  setTabRow({ height: 28, trailingInset: 0 });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-status--inline"));
};

// The same row while connected: tools only, with no location line below the tab row.
const inTabRowConnected: Play = async (ctx) => {
  const { setTabRow } = await import("./tabRow");
  setTabRow({ height: 28, trailingInset: 0 });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header[data-tab-row]"));
  if (ctx.document.querySelector(".acpmux-env-line, .acpmux-environment-row"))
    throw new Error("The chat header repeated the composer location");
};

export default agentPaneEntry({
  id: "agent-pane.header",
  title: "Header",
  area: "Agent pane",
  height: 320,
  covers: [
    "agent-session/acpmux/header/ChatHeaderStatus.tsx#ChatHeaderStatus",
    "agent-session/acpmux/header/ChatHeaderStatus.tsx#ChatHeaderInlineStatus",
  ],
  variants: {
    quiet: {
      note: "Connected after a turn: tools only, no title, status or repeated machine and folder label.",
      snapshot: chat(finished),
    },
    "long-branch": {
      note: "A chat with a long branch keeps the same quiet header: no machine, folder or branch label.",
      snapshot: chat(finished, { branch: "leo/inspector-overlay-default-and-hidden-empty-sections-follow-up" }),
    },
    disconnected: {
      note: "The daemon connection dropped.",
      snapshot: chat(finished, { connection: "disconnected" }),
    },
    reconnecting: {
      note: "Retrying after a failure; the failure is the tooltip.",
      snapshot: chat(finished, { connection: "connecting: connection refused by the local daemon" }),
    },
    "tab-row": {
      note: "The header shares the pane's tab row: tools only, with no extra location row.",
      snapshot: chat(finished),
      play: inTabRowConnected,
    },
    "tab-row-disconnected": {
      note: "The header shares the pane's tab row: the connection warning leads the tools.",
      snapshot: chat(finished, { connection: "disconnected" }),
      play: inTabRow,
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
