// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The unread marker and the jump pair in the whole pane (design/transcript-overlays.md): the "New"
// line, the unread banner in the top-start zone, and Jump up stacked on Jump to latest in the
// bottom-center zone, beside Session Info. Leo, 2026-11-10: "make it look integrated ... don't
// introduce any random stuff"; "you get jump to bottom, but then jump to, like, the last thread".
// The component looks (line, banner, light, dark and image) are agent-pane.since-divider.
// View every variant at each width, and in light and dark (?colorScheme=light / dark).
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER } from "./model";

const MARK = "gallery-unread:41";

const turns = (from: number, count: number, ago: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Check retry case ${from + index}`, ago - index * 2),
    assistant(
      `Case ${from + index} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
        3,
      ),
      ago - index * 2 - 1,
    ),
    summary(ago - index * 2 - 1, { status: "completed" }),
  ]).flat();

// Twelve turns the person saw, the line, then nine that ended while they were away (from 3:42).
const snapshot = chat(
  [
    ...turns(1, 12, 120),
    row(SINCE_DIVIDER, 60, {
      id: SINCE_DIVIDER,
      since: {
        key: MARK,
        seq: 41,
        turns: 9,
        recap: {
          key: "gallery-unread",
          text: "Retries now keep the request id; cases 13 to 21 pass. Next: the fuzz corpus, then the PR.",
          awayMs: 38 * 60_000,
        },
      },
    }),
    ...turns(13, 9, 58),
  ],
  { sinceKey: MARK },
);

const settle = async (ctx: Parameters<Play>[0]) =>
  ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_500);

const display = async (values: Record<string, unknown>) => {
  const { setChatDisplay } = await import("./chatDisplay");
  setChatDisplay(values);
};

/// Opens at the latest message, as a returning person does: the banner over the top, Jump up over
/// the composer (the line is far above), Jump to latest hidden (at the latest message). With the
/// banner off nothing draws it (SinceDivider.tsx `UnreadBanner`), so the view is ready once Jump up shows.
const atLatest =
  (values: Record<string, unknown> = {}): Play =>
  async (ctx) => {
    await display(values);
    await settle(ctx);
    const off = values["agentPane.display.unreadBanner"] === "off";
    await ctx.waitFor(() => ctx.document.querySelector(off ? ".acpmux-jump-up[data-shown]" : ".acpmux-since-jump"));
    if (off && ctx.document.querySelector(".acpmux-since-jump")) throw new Error("the banner draws while it is off");
  };

/// Scrolled to the middle by hand: the stop is the reader's place, so Jump up waits for the line.
const midChat: Play = async (ctx) => {
  await settle(ctx);
  await ctx.scroll({ selector: ".acpmux-scroll" }, 1_400);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest:not(.acpmux-jump-up)[data-shown]"));
};

const jumpedUp: Play = async (ctx) => {
  await settle(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-shown]"));
  await ctx.click({ selector: ".acpmux-jump-up" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-back]"));
};

/// The banner pressed: the transcript brings the line in, and the banner has done its job.
const lineInView: Play = async (ctx) => {
  await settle(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-since-jump[data-shown]"));
  await ctx.click({ selector: ".acpmux-since-jump__body" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-since"));
};

/// Jump up while it goes to unread turns (the person was away from the chat on screen: attention.ts,
/// acpmux hub/seen.rs). `look` draws a compared look over the chosen dot: an accent rim (`ring`) or
/// an accent arrow (`tint`), set here on the page alone so only the chosen look ships (jumpPair.css).
const unreadUp =
  (look: "dot" | "ring" | "tint" = "dot"): Play =>
  async (ctx) => {
    await display({ "agentPane.display.unreadBanner": "off" });
    await settle(ctx);
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-shown][data-unread]"));
    if (look === "dot") return;
    const style = ctx.document.createElement("style");
    style.textContent =
      look === "ring"
        ? ".acpmux-jump-up[data-unread]::after{opacity:0!important}.acpmux-jump-up[data-unread]{--glass-edge:var(--cmux-app-accent)}"
        : ".acpmux-jump-up[data-unread]::after{opacity:0!important}.acpmux-jump-up[data-unread] .acpmux-jump-latest__arrow{color:var(--cmux-app-accent)}";
    ctx.document.head.append(style);
  };

/// Nothing unread: the chat the person read through, scrolled to the latest message after reading
/// above. Jump up has no dot and goes to their own last prompt (the fallback).
const readThrough = chat([
  ...turns(1, 12, 120),
  ...Array.from({ length: 6 }, (_, index) =>
    assistant(
      `Step ${index + 1} of the long run: the fuzz corpus case passes, the request id holds, the retry stops. `.repeat(
        4,
      ),
      40 - index,
    ),
  ),
]);
const fallbackUp: Play = async (ctx) => {
  await settle(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-shown]"));
  if (ctx.document.querySelector(".acpmux-jump-up[data-unread]")) throw new Error("no unread: no dot");
};

/// Pressed from the latest message: the line lands near the top of the view, the first unseen turn
/// under it.
const landedNearTop: Play = async (ctx) => {
  await unreadUp()(ctx);
  await ctx.click({ selector: ".acpmux-jump-up" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-back]"));
  await ctx.waitFor(() => {
    const line = ctx.document.querySelector(".cv-since");
    const scroller = ctx.document.querySelector(".acpmux-scroll");
    if (!line || !scroller) return false;
    const from = line.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
    return from >= 0 && from < scroller.clientHeight / 5;
  });
};

const sessionInfo: Play = async (ctx) => {
  const { setHeaderState } = await import("./header/headerState");
  const { setSessionInfoOpen } = await import("./session-info/sessionInfoState");
  await display({ "agentPane.display.sessionInfo.placement": "push" });
  setHeaderState({ inspector: true });
  setSessionInfoOpen(true);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-toggle"));
  const toggle = '.acpmux-session-info-toggle[aria-pressed="false"]';
  if (ctx.document.querySelector(toggle)) await ctx.click({ selector: toggle });
  await settle(ctx);
};

const imageBackground: Play = async (ctx) => {
  const root = ctx.document.documentElement;
  root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
  root.style.setProperty("--agent-page-bg", "transparent");
  await settle(ctx);
};

export default agentPaneEntry({
  id: "agent-pane.unread-marker",
  title: "Unread marker and the jump pair",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx", "agent-session/acpmux/VirtualTranscript.tsx#JumpUp"],
  keywords: ["unread", "new since", "jump up", "jump to bottom", "banner", "idle", "attention"],
  variants: {
    "banner-expanded": {
      note: "Chosen: back in a chat that kept working, the banner at the top left reads 9 new turns since the time, with Mark read; Jump up waits over the composer.",
      snapshot,
      play: atLatest(),
    },
    "banner-collapsed": {
      note: "Collapsed (the chevron, kept as the setting): a small pill with the arrow and the count; still jumps.",
      snapshot,
      play: atLatest({ "agentPane.display.unreadBanner": "collapsed" }),
    },
    "banner-off": {
      note: "Off (right-click > Hide unread banner): only the line and Jump up; the line's right-click brings it back.",
      snapshot,
      // Off draws no banner (SinceDivider.tsx returns none), so this waits for Jump up instead and
      // holds the banner to being gone.
      play: async (ctx) => {
        await display({ "agentPane.display.unreadBanner": "off" });
        await settle(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-shown]"));
        if (ctx.document.querySelector(".acpmux-since-jump"))
          throw new Error("with the banner off, the unread banner must not draw");
      },
    },
    "jump-pair": {
      note: "Mid-chat: Jump up (to the New line) stacked on Jump to latest, one column on the composer's center line.",
      snapshot,
      play: midChat,
    },
    "jump-back": {
      note: "After Jump up: the view is at the line and the button points down; a second press or Esc goes back.",
      snapshot,
      play: jumpedUp,
    },
    "line-in-view": {
      note: "The banner pressed: the New line in the message rhythm (one control row, its recap under it), the banner gone.",
      snapshot,
      play: lineInView,
    },
    "unread-dot": {
      note: "Chosen: away from the chat on screen while it worked (no input for 60 s), back at the latest message: Jump up carries the theme's accent dot, the sidebar's unread dot, and goes to the New line.",
      snapshot,
      play: unreadUp("dot"),
    },
    "unread-ring": {
      note: "Compared: the disc's rim in the accent instead of a dot. Reads as focus or selection, not news.",
      snapshot,
      play: unreadUp("ring"),
    },
    "unread-tint": {
      note: "Compared: the arrow in the accent. Too quiet at 14 pt on glass, and lost over an image.",
      snapshot,
      play: unreadUp("tint"),
    },
    "unread-landed": {
      note: "Pressed from the latest message: the New line near the top of the view, the first turn the person did not see right under it; the button points down to go back.",
      snapshot,
      play: landedNearTop,
    },
    "nothing-unread": {
      note: "Nothing unread (read through while attending): no dot; Jump up goes to the person's own last prompt or where they last stopped scrolling.",
      snapshot: readThrough,
      play: fallbackUp,
    },
    "with-session-info": {
      note: "Session Info pushes at the end edge; the banner keeps to the column's start, the pair to its center: no overlap.",
      snapshot,
      play: sessionInfo,
    },
    "image-background": {
      note: "Over a background image: the glass banner and pair, the accent line, all from the theme's tokens.",
      snapshot,
      play: imageBackground,
    },
  },
});
