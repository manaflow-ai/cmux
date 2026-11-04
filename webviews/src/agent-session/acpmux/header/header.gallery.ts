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

// The same row while connected: only the tools (the pane's tab names the chat), with no location line below the tab row.
const inTabRowConnected: Play = async (ctx) => {
  const { setTabRow } = await import("./tabRow");
  setTabRow({ height: 28, trailingInset: 0 });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header[data-tab-row] .acpmux-handoff-header-tools"));
  if (ctx.document.querySelector(".acpmux-header[data-tab-row] .acpmux-thread-title"))
    throw new Error("The tab row repeated the chat's title");
  if (ctx.document.querySelector(".acpmux-env-line, .acpmux-environment-row"))
    throw new Error("The chat header repeated the composer location");
};

// A longer chat for the one-tab row: enough rows to scroll some under the row.
const longer = [
  ...Array.from({ length: 6 }, (_, n) => [
    user(`Step ${n + 1}: tighten the retry policy for the fetch helper`, 30 - n * 3),
    assistant(
      "Done. GETs retry three times with jittered backoff; POSTs retry only with an idempotency key. The tests cover both paths.",
      29 - n * 3,
    ),
  ]).flat(),
  summary(9, { status: "completed" }),
];

// A pane with one tab (header/tabRow.ts `soloTab`): the transcript runs up under the row, which floats over it.
// `blur` sets the light blur under the tools; `scroll` moves rows under the row (0: at rest, the first message
// where it was below the row).
const soloTab =
  (blur: number | undefined, scroll: number): Play =>
  async (ctx) => {
    const { setTabRow } = await import("./tabRow");
    setTabRow({ height: 38, trailingInset: 0, soloTab: true });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-stage[data-solo-tab] > .acpmux-scroll .acpmux-row"));
    const stage = ctx.document.querySelector<HTMLElement>(".acpmux-stage")!;
    if (blur !== undefined) stage.style.setProperty("--acpmux-solo-blur", `${blur}px`);
    const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-stage > .acpmux-scroll")!;
    scroller.scrollTop = scroll;
    await ctx.waitFor(() => scroll === 0 || scroller.hasAttribute("data-fade-top"));
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
    setChatDisplay({ "agentPane.display.sessionInfo.placement": placement });
    setSessionInfoOpen(open);
    // A pane that cannot hold a readable chat beside it, or a short one where it is a popover, opens
    // Session Info only from the person's toggle (SessionInfo.tsx sessionInfoFits).
    if (open) {
      const toggle = '.acpmux-session-info-toggle[aria-pressed="false"]';
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-toggle"));
      if (ctx.document.querySelector(toggle)) await ctx.click({ selector: toggle });
    }
    // Push pushes only where the transcript's column keeps its width beside the panel; in this 760px pane a
    // push would narrow it, so it lies over the chat instead (#33037, SessionInfo.tsx pushKeepsColumn).
    const drawn = placement === "push" ? "overlay" : placement;
    await ctx.waitFor(() =>
      open
        ? ctx.document.querySelector(`.acpmux-session-info[data-placement="${drawn}"][data-presence="shown"]`)
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
      note: "The header shares the pane's tab row: only its tools, no title (the tab names the chat) and no extra location row.",
      snapshot: chat(finished),
      play: inTabRowConnected,
    },
    "solo-tab-rest": {
      note: "One tab in the pane: no band under the row. At rest the first message sits where it did below the row.",
      snapshot: chat(longer),
      play: soloTab(undefined, 0),
    },
    "solo-tab-blur": {
      note: "Chosen: one tab, scrolled. Rows run up under the tools, fading out across the row under a light 6px blur; the tools stay legible.",
      snapshot: chat(longer),
      play: soloTab(undefined, 90),
    },
    "solo-tab-fade-only": {
      note: "Alternative: the fade alone, no blur. Text under the tools stays sharp and reads as clutter behind them.",
      snapshot: chat(longer),
      play: soloTab(0, 90),
    },
    "solo-tab-blur-strong": {
      note: "Alternative: a 14px blur. Smears the row into a frosted band, which brings back the band this removes.",
      snapshot: chat(longer),
      play: soloTab(14, 90),
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
      note: "Push chosen in a 760px pane: a push would narrow the conversation's column, so Session Info lies over the chat instead; the tools keep their full-width alignment.",
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
