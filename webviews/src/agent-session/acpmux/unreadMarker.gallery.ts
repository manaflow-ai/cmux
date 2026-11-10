// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The unread marker in the whole pane (design/transcript-overlays.md): the "New" line, and the one
// jump control in the bottom-center zone pointing up to it with the count, beside Session Info.
// Leo, 2026-11-10: "make it look integrated ... don't introduce any random stuff"; "There's also no
// point doubling up on this." The line's looks are agent-pane.since-divider; the control's states
// are agent-pane.jump-control.
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

/// Opens at the latest message, as a returning person does: the one jump control over the composer
/// points up to the line (far above) with the count.
const atLatest =
  (values: Record<string, unknown> = {}): Play =>
  async (ctx) => {
    await display(values);
    await settle(ctx);
    await ctx.waitFor(() => ctx.document.querySelector('.acpmux-jump-latest[data-jump="unread"][data-shown]'));
  };

/// The control pressed: the transcript brings the line in, and the control turns to Jump to latest.
const lineInView: Play = async (ctx) => {
  await settle(ctx);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-jump-latest[data-jump="unread"][data-shown]'));
  await ctx.click({ selector: ".acpmux-jump-latest" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-since"));
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
  title: "Unread marker and the jump control",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx"],
  keywords: ["unread", "new since", "jump up", "jump to bottom"],
  variants: {
    "unread-above": {
      note: "Back in a chat that kept working: the one control over the composer points up to the New line with 9 new turns.",
      snapshot,
      play: atLatest(),
    },
    "unread-off": {
      note: "The unread setting off (the line's right-click): the control stays hidden at the latest message; the line is still in the rhythm.",
      snapshot,
      play: async (ctx) => {
        await display({ "agentPane.display.unreadBanner": "off" });
        await settle(ctx);
        if (ctx.document.querySelector('.acpmux-jump-latest[data-jump="unread"][data-shown]'))
          throw new Error("with the unread setting off, the control must not point up");
      },
    },
    "line-in-view": {
      note: "The control pressed: the New line in the message rhythm (one control row, its recap under it); the control now points down.",
      snapshot,
      play: lineInView,
    },
    "with-session-info": {
      note: "Session Info pushes at the end edge; the control keeps to the composer's center: no overlap.",
      snapshot,
      play: sessionInfo,
    },
    "image-background": {
      note: "Over a background image: the glass control and its count, the accent line, all from the theme's tokens.",
      snapshot,
      play: imageBackground,
    },
  },
});
