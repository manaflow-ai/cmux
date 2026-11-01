// l10n-allow-file: gallery fixtures (sample chats and connection errors), not shipped UI.
// The pane header: the chat's plain title, tools and connection failures only.
// Where a started chat runs is Session Info's Environment; the header never repeats it.
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

// The same row while connected: the plain title and tools, with no location line below the tab row.
const inTabRowConnected: Play = async (ctx) => {
  const { setTabRow } = await import("./tabRow");
  setTabRow({ height: 28, trailingInset: 0 });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header[data-tab-row]"));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thread-title"));
  if (ctx.document.querySelector(".acpmux-env-line, .acpmux-environment-row"))
    throw new Error("The chat header repeated the composer location");
};

const sessionInfo =
  (placement: "overlay" | "push", open: boolean): Play =>
  async (ctx) => {
    const { setTabRow } = await import("./tabRow");
    const { setHeaderState } = await import("./headerState");
    const { setChatDisplay } = await import("../chatDisplay");
    const { setSessionInfoOpen } = await import("../session-info/sessionInfoState");
    setTabRow({ height: 28, trailingInset: 0 });
    setHeaderState({ inspector: true });
    setChatDisplay({ "agentPane.display.inspector.placement": placement });
    setSessionInfoOpen(open);
    await ctx.waitFor(() =>
      open
        ? ctx.document.querySelector(`.acpmux-session-info[data-placement="${placement}"][data-presence="shown"]`)
        : !ctx.document.querySelector(".acpmux-session-info"),
    );
  };

const standaloneHeight =
  (height: number): Play =>
  async (ctx) => {
    const { setTabRow } = await import("./tabRow");
    setTabRow({ height: 0, trailingInset: 0 });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header:not([data-tab-row])"));
    ctx.document
      .querySelector<HTMLElement>(".acpmux-shell")!
      .style.setProperty("--acpmux-header-height", `${height}px`);
  };

export default agentPaneEntry({
  id: "agent-pane.header",
  title: "Header",
  area: "Agent pane",
  height: 320,
  covers: [
    "agent-session/acpmux/header/ChatHeaderStatus.tsx#ChatHeaderStatus",
    "agent-session/acpmux/header/ChatHeaderStatus.tsx#ChatHeaderInlineStatus",
    "agent-session/acpmux/header/ThreadTitle.tsx#ThreadTitle",
  ],
  variants: {
    "standalone-compact": {
      note: "Chosen: a 28px row around the 24px controls, with 2px above and below. No machine/folder label or extra band.",
      snapshot: chat(finished),
      play: standaloneHeight(28),
    },
    "standalone-roomy": {
      note: "Alternative: 32px row. More vertical padding without increasing the actual button targets.",
      snapshot: chat(finished),
      play: standaloneHeight(32),
    },
    "standalone-tight": {
      note: "Alternative: 24px row. Fits the controls exactly, but leaves no vertical breathing room around their targets.",
      snapshot: chat(finished),
      play: standaloneHeight(24),
    },
    quiet: {
      note: "Connected after a turn: the title opens chat actions; no repeated machine or folder label.",
      snapshot: chat(finished),
    },
    "long-branch": {
      note: "A chat with a long branch keeps the same quiet header: no machine, folder or branch label.",
      snapshot: chat(finished, { branch: "leo/inspector-overlay-default-and-hidden-empty-sections-follow-up" }),
    },
    disconnected: {
      note: "The daemon connection dropped while the pane asks for it again: the header stays quiet.",
      snapshot: chat(finished, { connection: "disconnected" }),
    },
    reconnecting: {
      note: "Retrying after a failure is quiet: no Reconnecting in the header; a lasting failure is one line above the composer.",
      snapshot: chat(finished, { connection: "connecting: connection refused by the local daemon" }),
    },
    "tab-row": {
      note: "The header shares the pane's tab row: the title menu stays available beside the tools, with no extra location row.",
      snapshot: chat(finished),
      play: inTabRowConnected,
    },
    "tab-row-disconnected": {
      // A dropped socket the pane is asking for again is quiet (paneHeader `hostRecovering`), so the
      // warning this state shows in the tab row is a failed chat's.
      note: "The header shares the pane's tab row: the connection warning leads the tools.",
      snapshot: chat(finished, { connection: "error: the agent process exited before it answered" }),
      play: inTabRow,
    },
    "session-info-overlay-closed": {
      note: "Session Info closed, floating placement. The tools remain at the pane's trailing edge.",
      snapshot: chat(finished),
      play: sessionInfo("overlay", false),
    },
    "session-info-overlay-open": {
      note: "Session Info floats below the tools. Each tool stays visible on the same transparent row.",
      snapshot: chat(finished),
      play: sessionInfo("overlay", true),
    },
    "session-info-push-closed": {
      note: "Session Info closed with Push always selected. The header reserves the same tool strip.",
      snapshot: chat(finished),
      play: sessionInfo("push", false),
    },
    "session-info-push-open": {
      note: "Push always narrows the conversation below the header; the tools keep their full-width alignment.",
      snapshot: chat(finished),
      play: sessionInfo("push", true),
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
