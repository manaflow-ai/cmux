// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The jump control's look (jumpPair.experiment.ts, jumpPair.css, VirtualTranscript.tsx `JumpToLatest`,
// one disc that turns up to unseen rows: jumpControl.ts). Leo, 2026-11-12, on the fisheye disc over the transcript: "I feel like this jump to
// top button is a little bit strange-looking, no? Like, did we redesign that [stuff] yet?"
// One disc at a time, never two (Leo, 2026-11-12: the two stacked are "maybe a bit extra?"). Most
// variants park the reader mid-chat below an unread "New" line, so the disc points up over real prose;
// the `-up` variants leave them at the latest message, the line far above, where it points up too; the
// `-latest` ones park above the line, where nothing unseen lies above and it is Jump to latest;
// `single` (#42056) never turns up; `frosted-image` over a wallpaper. `pair`, `up` and `latest` pin no arm, so View Compare arms draws
// them once per look side by side; the other variants pin one look each. Light and dark:
// ?colorScheme=light / dark.
import { agentPaneEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER, type AcpmuxRow } from "./model";
import { jumpPairLook, type JumpPairLook } from "./jumpPair.experiment";

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

/// Each row with the seq of the record that began it, as the pane's rows carry.
const numbered = (rows: AcpmuxRow[]): AcpmuxRow[] =>
  rows.map((each, index) => ({ ...each, seq: each.seq ?? index + 1 }));

// Ten turns the person saw (30 rows: their cursor), the unread line, then twelve that ended while
// they were away.
const snapshot = chat(
  numbered([
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
  ]),
  { sinceKey: MARK, readThrough: 30 },
);

const scroller = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-scroll");

const shown = (ctx: PlayContext, jump: "up" | "latest") =>
  ctx.document.querySelectorAll(".acpmux-jump-latest[data-shown]").length === 1 &&
  ctx.document.querySelector(`.acpmux-jump-latest[data-jump="${jump}"][data-shown]`) !== null;

/// Below the unread line and above the latest message, with prose under the control: it points up
/// (the first unseen row is above the view).
const park: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  const view = scroller(ctx)!;
  await ctx.scroll({ selector: ".acpmux-scroll" }, view.scrollHeight - view.clientHeight - 700);
  await ctx.waitFor(() => shown(ctx, "up"));
};

/// At the latest message, the unread line far above: the one disc points up.
const atLatest: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  await ctx.waitFor(() => shown(ctx, "up"));
};

/// Above the unread line, nothing unseen above the view: the one disc is Jump to latest.
const above: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  await ctx.scroll({ selector: ".acpmux-scroll" }, 0);
  await ctx.waitFor(() => shown(ctx, "latest"));
};

/// The single look (#42056): parked where the disc would point up, it stays Jump to latest.
const parkSingle: Play = async (ctx) => {
  await ctx.waitFor(() => (scroller(ctx)?.scrollHeight ?? 0) > 2_000);
  const view = scroller(ctx)!;
  await ctx.scroll({ selector: ".acpmux-scroll" }, view.scrollHeight - view.clientHeight - 700);
  await ctx.waitFor(() => shown(ctx, "latest"));
};

const overImage: Play = async (ctx) => {
  const root = ctx.document.documentElement;
  root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
  root.style.setProperty("--agent-page-bg", "transparent");
  await park(ctx);
};

const look = (arm: JumpPairLook) => ({ experiments: { [jumpPairLook.id]: arm } });

export default agentPaneEntry({
  id: "agent-pane.jump-pair-look",
  title: "Jump to latest and Jump up: the look",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#JumpToLatest",
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
      note: "The disc pointing up in the app's look (the experiment's arm, frosted by default); View Compare arms puts every look side by side.",
      snapshot,
      play: park,
    },
    up: {
      note: "Jump up at the latest message, the New line far above, in the app's look; View Compare arms puts every look side by side.",
      snapshot,
      play: atLatest,
    },
    "labeled-up": {
      note: "Labeled Jump up: its own words, at the latest message.",
      snapshot,
      play: atLatest,
      ...look("labeled"),
    },
    latest: {
      note: "Above the New line: nothing unseen above, so the one disc is Jump to latest, in the app's look.",
      snapshot,
      play: above,
    },
    "labeled-latest": {
      note: "Labeled Jump to latest: its own words, above the New line.",
      snapshot,
      play: above,
      ...look("labeled"),
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
      note: 'Single: the frosted disc never turns up; it is Jump to latest alone (Leo, 2026-11-12: "maybe a bit extra?").',
      snapshot,
      play: parkSingle,
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
