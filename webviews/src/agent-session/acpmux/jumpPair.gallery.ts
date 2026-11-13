// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The jump pair's look (jumpPair.experiment.ts, jumpPair.css, VirtualTranscript.tsx `JumpToLatest`
// and `JumpUp`). Leo, 2026-11-12, on the fisheye disc over the transcript: "I feel like this jump to
// top button is a little bit strange-looking, no? Like, did we redesign that [stuff] yet?"
// Only one of the two shows at a time (Leo, 2026-11-12: the two stacked are "maybe a bit extra?"):
// the variants park the reader mid-chat, scrolled up, where Jump to latest shows over real prose; the
// `-up` variants leave them at the latest message under an unread "New" line far above, where Jump up
// shows; `single` pins the look that draws no Jump up at all; `frosted-image` over a wallpaper. `pair`
// and `up` pin no arm, so View Compare arms draws them once per look side by side; the other variants
// pin one look each. Light and dark:
// ?colorScheme=light / dark.
import { agentPaneEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER } from "./model";
import { jumpPairLook, type JumpPairLook } from "./jumpPair.experiment";
import { jumpUpButton } from "./jumpUp.experiment";

const MARK = "gallery-jump-pair:41";

const turns = (from: number, count: number, ago: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Check retry case ${from + index}`, ago - index * 2),
    assistant(
      `Case ${from + index} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. The next check verifies that the same response reaches the caller exactly once. `.repeat(
        3,
      ),
      ago - index * 2 - 1,
    ),
    summary(ago - index * 2 - 1, { status: "completed" }),
  ]).flat();

// Ten turns the person saw, the unread line, then twelve that ended while they were away.
const snapshot = chat(
  [
    ...turns(1, 10, 120),
    row(SINCE_DIVIDER, 80, {
      id: SINCE_DIVIDER,
      since: {
        key: MARK,
        seq: 41,
        turns: 12,
        recap: {
          key: "gallery-jump-pair",
          text: "Retries now keep the request id; cases 11 to 22 pass.",
          awayMs: 38 * 60_000,
        },
      },
    }),
    ...turns(11, 12, 78),
  ],
  { sinceKey: MARK },
);

const scroller = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-scroll");

const shown = (ctx: PlayContext, selector: string) => ctx.document.querySelector(`${selector}[data-shown]`) !== null;
const LATEST = ".acpmux-jump-latest:not(.acpmux-jump-up)";
const UP = ".acpmux-jump-up";

/// Above the latest message, with prose under the button: Jump to latest shows, and Jump up waits.
const park: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  const view = scroller(ctx)!;
  await ctx.scroll({ selector: ".acpmux-scroll" }, view.scrollHeight - view.clientHeight - 700);
  await ctx.waitFor(() => shown(ctx, LATEST) && !shown(ctx, UP));
};

/// At the latest message, the unread line far above: Jump up shows, alone. The single look draws no
/// Jump up, so there neither button shows.
const atLatest: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  if (ctx.document.querySelector(`${LATEST}[data-look="single"]`)) {
    await ctx.waitFor(() => !shown(ctx, LATEST));
    return;
  }
  await ctx.waitFor(() => shown(ctx, UP) && !shown(ctx, LATEST));
};

const overImage: Play = async (ctx) => {
  const root = ctx.document.documentElement;
  root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
  root.style.setProperty("--agent-page-bg", "transparent");
  await park(ctx);
};

const look = (arm: JumpPairLook, up = false) => ({
  experiments: { [jumpPairLook.id]: arm, ...(up ? { [jumpUpButton.id]: "on" } : {}) },
});

export default agentPaneEntry({
  id: "agent-pane.jump-pair-look",
  title: "Jump to latest and Jump up: the look",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#JumpToLatest",
    "agent-session/acpmux/VirtualTranscript.tsx#JumpUp",
    "agent-session/acpmux/jumpPair.css",
    "agent-session/acpmux/jumpPair.experiment.ts",
  ],
  keywords: ["jump to latest", "jump up", "jump to bottom", "scroll to bottom", "fisheye"],
  checks: {
    anchorMovePx: { value: 0, reason: "Parking the reader moves only the transcript; the composer holds still." },
  },
  experiment: { definition: jumpPairLook, script: [{ name: "Park mid-chat under the New line", run: park }] },
  variants: {
    pair: {
      note: "Jump to latest in the app's look (the experiment's arm, frosted by default); View Compare arms puts every look side by side.",
      snapshot,
      play: park,
    },
    up: {
      note: "Jump up alone at the latest message, the New line far above, in the app's look; View Compare arms puts every look side by side.",
      snapshot,
      play: atLatest,
      experiments: { [jumpUpButton.id]: "on" },
    },
    "labeled-up": {
      note: "Labeled Jump up: its own words, alone at the latest message.",
      snapshot,
      play: atLatest,
      ...look("labeled", true),
    },
    frosted: {
      note: "Selected (ships): a 32 px frosted disc at the composer's glass level; the words under it frost, nothing bends.",
      snapshot,
      play: park,
      ...look("frosted"),
    },
    labeled: {
      note: "Labeled: the same glass as short rounded rectangles with the arrow and its words, the Needs you pill's shape.",
      snapshot,
      play: park,
      ...look("labeled"),
    },
    stacked: {
      note: "Stacked: frosted rounded squares in the Needs you pill's radius, a hairline apart, one compact column.",
      snapshot,
      play: park,
      ...look("stacked"),
    },
    single: {
      note: 'Single: the frosted disc alone, no Jump up over it (Leo, 2026-11-12: "maybe a bit extra?").',
      snapshot,
      play: park,
      ...look("single"),
    },
    lens: {
      note: "Before: the fisheye lens disc; the words under it magnify and bend behind the arrow.",
      snapshot,
      play: park,
      ...look("lens"),
    },
    "frosted-image": {
      note: "The shipped look over a wallpaper: still glass, the art shows through the frost.",
      snapshot,
      play: overImage,
      ...look("frosted"),
    },
  },
});
