// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The unread marker in the whole pane (design/transcript-overlays.md): the "New" line and the
// unread banner in the top-start zone, beside Session Info. The banner is off by default and Jump up
// is gone (Lawrence, 2026-11-11 standup: two up arrows, match Codex). Leo, 2026-11-10: "make it look integrated ... don't
// introduce any random stuff"; "you get jump to bottom, but then jump to, like, the last thread".
// The component looks (line, banner, light, dark and image) are agent-pane.since-divider.
// View every variant at each width, and in light and dark (?colorScheme=light / dark).
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { activity, assistant, chat, row, summary, tool, user } from "../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER } from "./model";
import { jumpPairLook } from "./jumpPair.experiment";
import { jumpUpButton } from "./jumpUp.experiment";
import { sinceLook } from "./conversation/sinceLook.experiment";
import { JUMP_LATEST_SHOWN } from "./transcriptSelectors";

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

// "N new messages" (Leo, 2026-11-15: "we needto properly do somthing like this in the gui somehow",
// of the terminal chat's rule). Each chat below is what a returning person opens: what they had seen,
// the line, then `count` messages (replies; the tool runs between them are not news and never count,
// conversation/sinceNews.ts) that came while they were away. A return lands at the line
// (`sinceLands`), so each capture shows where the new part starts.
const NEW_MARK = "gallery-new-messages:7";
const newLine = (minutes: number) =>
  row(SINCE_DIVIDER, minutes, { id: SINCE_DIVIDER, since: { key: NEW_MARK, seq: 7, turns: 1 } });
/// `count` messages after the line: a tool run and a reply per step, a turn's end every five.
const newMessages = (count: number, ago: number) =>
  Array.from({ length: count }, (_, index) => {
    const step = index + 1;
    const at = ago - index * 0.2;
    const run = activity([tool(`Run retry case ${step}`, "execute", "completed")], at);
    const reply = assistant(
      `Case ${step} passes: the client keeps the request id and stops after the last attempt.`,
      at - 0.1,
    );
    return index % 5 === 4 ? [run, reply, summary(at - 0.1, { status: "completed" })] : [run, reply];
  }).flat();
const seenTurns = turns(1, 6, 120);
const newChat = (before: ReturnType<typeof row>[], count: number) =>
  chat([...seenTurns, ...before, newLine(61), ...newMessages(count, 60)], { sinceKey: NEW_MARK, sinceLands: true });
const fewNew = newChat([user("Run the retry cases again and tell me when they pass", 62)], 3);
const manyNew = newChat([user("Run the retry cases again and tell me when they pass", 62)], 157);
const afterUser = newChat(
  [
    user("Check retry case 6", 66),
    assistant("Case 6 passes.", 65),
    summary(65, { status: "completed" }),
    user("ok now run the whole suite, then the fuzz corpus, and fix whatever breaks", 62),
  ],
  24,
);
const afterTool = newChat(
  [
    user("Run the whole suite", 66),
    activity(
      [tool("bun test src/fetch", "execute", "completed"), tool("Read src/fetch/retry.ts", "read", "completed")],
      63,
    ),
  ],
  12,
);

/// A return: the view lands at the line, not the latest message.
const landed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-since[data-shown]"));
  await ctx.waitFor(() => {
    const line = ctx.document.querySelector(".cv-since");
    const view = ctx.document.querySelector(".acpmux-scroll");
    if (!line || !view) return false;
    const box = line.getBoundingClientRect();
    const frame = view.getBoundingClientRect();
    return box.top >= frame.top && box.bottom <= frame.bottom;
  });
};

const settle = async (ctx: Parameters<Play>[0]) =>
  ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_500);

const display = async (values: Record<string, unknown>) => {
  const { setChatDisplay } = await import("./chatDisplay");
  setChatDisplay(values);
};

/// Opens at the latest message, as a returning person does: the banner over the top while it is on,
/// Jump to latest hidden (at the latest message).
const atLatest =
  (values: Record<string, unknown> = {}): Play =>
  async (ctx) => {
    await display(values);
    await settle(ctx);
    if (values["agentPane.display.unreadBanner"] !== undefined)
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-since-jump"));
    else if (ctx.document.querySelector(".acpmux-since-jump")) throw new Error("the banner draws while it is off");
  };

/// Scrolled to the middle by hand: Jump to latest shows, and Jump up stays away while it does.
const midChat: Play = async (ctx) => {
  await settle(ctx);
  await ctx.scroll({ selector: ".acpmux-scroll" }, 1_400);
  await ctx.waitFor(() => ctx.document.querySelector(JUMP_LATEST_SHOWN));
};

const jumpedUp: Play = async (ctx) => {
  await settle(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-shown]"));
  await ctx.click({ selector: ".acpmux-jump-up" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-up[data-back]"));
};

/// The banner pressed: the transcript brings the line in, and the banner has done its job.
const lineInView: Play = async (ctx) => {
  await display({ "agentPane.display.unreadBanner": "expanded" });
  await settle(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-since-jump[data-shown]"));
  await ctx.click({ selector: ".acpmux-since-jump__body" });
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
  title: "Unread marker",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: ["agent-session/acpmux/conversation/SinceDivider.tsx", "agent-session/acpmux/VirtualTranscript.tsx#JumpUp"],
  // Jump up is off by default; `on` retains its exclusive display with Jump to latest.
  experiment: { definition: jumpUpButton, script: [{ name: "scroll to the middle", run: midChat }] },
  keywords: ["unread", "new since", "new messages", "jump to bottom", "banner"],
  variants: {
    "new-few": {
      note: 'A return with 3 new messages: "3 new messages" on the line under the person\'s last message (the shipped look, at the end of the next Worked for rule); the view opens there.',
      snapshot: fewNew,
      play: landed,
    },
    "new-many": {
      note: 'A return after a long run: "157 new messages"; the view lands at the line, the new part below.',
      snapshot: manyNew,
      play: landed,
    },
    "new-many-thin-line": {
      note: 'The thin line look (A): "157 new messages" muted at the center of the hairline, as the terminal chat draws it; no height.',
      snapshot: manyNew,
      play: landed,
      experiments: { [sinceLook.id]: "line" },
    },
    "after-user-message": {
      note: "The line straight after the person's own message (Leo's screenshot): what they asked, then where the replies they missed begin.",
      snapshot: afterUser,
      play: landed,
    },
    "after-tool-run": {
      note: "The line after a tool run the person saw: the new part starts with the next run, the count says how many replies followed.",
      snapshot: afterTool,
      play: landed,
    },
    "banner-off": {
      note: "Chosen (the default): no banner and no Jump up; only the New line in the transcript, as Codex.",
      snapshot,
      play: atLatest(),
    },
    "banner-expanded": {
      note: "Expanded (Settings > Unread Banner): the banner at the top left reads the line's count (9 new messages) since the time, with Mark read.",
      snapshot,
      play: atLatest({ "agentPane.display.unreadBanner": "expanded" }),
    },
    "banner-collapsed": {
      note: "Collapsed (the chevron, kept as the setting): a small pill with the arrow and the count; still jumps.",
      snapshot,
      play: atLatest({ "agentPane.display.unreadBanner": "collapsed" }),
    },
    "jump-pair": {
      note: 'Mid-chat: Jump to latest alone; Jump up never stacks on it (Leo, 2026-11-12: "a bit extra").',
      snapshot,
      play: midChat,
    },
    "jump-back": {
      note: "After Jump up: the view is at the line and Jump to latest takes over; Esc goes back.",
      snapshot,
      play: jumpedUp,
      // Jump up draws only in the pair looks; the default is Jump to latest alone (jumpPair.experiment.ts).
      experiments: { [jumpUpButton.id]: "on", [jumpPairLook.id]: "frosted" },
    },
    "line-in-view": {
      note: "The banner pressed: the New line over the gap (no height, its recap under it), the banner gone.",
      snapshot,
      play: lineInView,
    },
    "with-session-info": {
      note: "Session Info pushes at the end edge; the banner keeps to the column's start: no overlap.",
      snapshot,
      play: sessionInfo,
    },
    "image-background": {
      note: "Over a background image: the glass banner and the accent line, all from the theme's tokens.",
      snapshot,
      play: imageBackground,
    },
  },
});
