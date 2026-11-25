// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// Where the jump stack stands over the composer (jumpPlace.experiment.ts, jumpPlace.css, jumpPlace.ts,
// App.tsx `data-jump-place` / `data-jump-side`). Leo, 2026-11-21, of Jump to latest's disc standing
// right on the tucked hat's "^ 3" pill: "this is uncomfortably tight. didn't we say we wanted to move
// these to the side or smth?" Every variant is the conflict: a long transcript parked mid-chat so Jump
// to latest shows, and the composer hat tucked (agentPane.display.trayTucked) with three subagents
// running, so the pull tab reads "^ 3". Leo, 2026-11-22, after `end` shipped (#48658): "why'd the
// jump to bottom move to the right. ... if it was between the jump to bottom and the composer hat
// thing, the composer hat hidden bit was the one to move to the right. or left." So `center` ships
// again and the pill moves aside (hatPillPlace.experiment.ts): the `pill-*` variants compare where it
// goes and how it looks; `end`, `start` and `corner` keep #48658's arms for the record.
// View at every width (narrow 420, normal 900, wide 1600); light and dark: ?colorScheme=light / dark.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
import { hatPillPlace, type HatPillPlace } from "./hatPillPlace.experiment";
import { jumpLatestPlace, type JumpLatestPlace } from "./jumpPlace.experiment";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { JUMP_LATEST, JUMP_LATEST_SHOWN } from "./transcriptSelectors";

const TUCKED = "agentPane.display.trayTucked";
const HANDLE = "agentPane.display.trayHandle";

const running = (name: string, minutes: number): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task: name,
  state: "running",
  startedAt: minutesAgo(minutes),
});

// Twenty-four finished turns, then a turn that is still working with three subagents running.
const history = Array.from({ length: 24 }, (_, index) => [
  user(`Check retry case ${index + 1}`, 60 - index * 2),
  assistant(
    `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
      3,
    ),
    59 - index * 2,
  ),
  summary(59 - index * 2, { status: "completed" }),
]).flat();
const working = (agents: Subagent[], said: string) =>
  chat(
    [
      ...history,
      user("Review the retry change from three sides", 6),
      row(SUBAGENTS, 5.5, { subagents: agents }),
      assistant(said, 4),
    ],
    { isWorking: true },
  );
const snapshot = working(
  [running("Review the retry loop", 5), running("Review the tests", 5), running("Review the docs", 5)],
  "Three reviewers are reading the change now.",
);
// The same chat with 128 subagents running: the pill reads "^ 128" (never "^ 99+").
const crowded = working(
  Array.from({ length: 128 }, (_, index) => running(`Review shard ${index + 1}`, 5)),
  "128 reviewers are reading the change now.",
);

type Options = { info?: "push"; handle?: "left" | "right"; tucked?: boolean };

/** The chat's display push: the hat tucked unless `tucked` is false, its handle where asked. */
const display = ({ handle, tucked = true }: Options = {}) => ({
  ...(tucked ? { [TUCKED]: true } : {}),
  ...(handle ? { [HANDLE]: handle } : {}),
});

const park =
  (options: Options = {}): Play =>
  async (ctx) => {
    if (options.info) {
      const { setHeaderState } = await import("./header/headerState");
      const { setChatDisplay } = await import("./chatDisplay");
      const { setSessionInfoOpen } = await import("./session-info/sessionInfoState");
      setHeaderState({ inspector: true });
      // setChatDisplay replaces every key, so the tucked hat and the handle go in with the placement.
      setChatDisplay({ ...display(options), "agentPane.display.sessionInfo.placement": options.info });
      setSessionInfoOpen(true);
      const toggle = '.acpmux-session-info-toggle[aria-pressed="false"]';
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-toggle"));
      if (ctx.document.querySelector(toggle)) await ctx.click({ selector: toggle });
      await ctx.waitFor(() => ctx.document.querySelector('.acpmux-session-info[data-presence="shown"]'));
    }
    await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_000);
    const hat = options.tucked === false ? ".acpmux-running-tray" : ".acpmux-tray-pull__tab";
    await ctx.waitFor(() => ctx.document.querySelector(hat));
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_200);
    await ctx.waitFor(() => ctx.document.querySelector(JUMP_LATEST_SHOWN));
    if (!ctx.document.querySelector(JUMP_LATEST)) throw new Error("no Jump to latest");
  };

const arm = (place: JumpLatestPlace, pill: HatPillPlace = "end") => ({
  experiments: { [jumpLatestPlace.id]: place, [hatPillPlace.id]: pill },
});

export default agentPaneEntry({
  id: "agent-pane.jump-place",
  title: "Jump to latest on the center line, the tucked composer hat's pill beside it",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: [
    "agent-session/acpmux/jumpPlace.css",
    "agent-session/acpmux/jumpPlace.experiment.ts",
    "agent-session/acpmux/jumpPlace.ts",
    "agent-session/acpmux/hatPillPlace.experiment.ts",
    "agent-session/acpmux/subagents/TrayPullTab.tsx",
    "agent-session/acpmux/VirtualTranscript.tsx#JumpToLatest",
  ],
  keywords: ["jump to latest", "jump to bottom", "composer hat", "tray", "pull tab", "side"],
  checks: {
    anchorMovePx: { value: 0, reason: "Parking the reader moves only the transcript; the composer holds still." },
  },
  experiment: { definition: hatPillPlace, script: [{ name: "Park mid-chat, the hat tucked", run: park() }] },
  variants: {
    "pill-end": {
      note: "Selected (ships): Jump to latest back on the composer's center line; the hat's glass \"^ 3\" pill at the composer's end edge, 12px in.",
      snapshot,
      display: display(),
      play: park(),
      ...arm("center", "end"),
    },
    "pill-start": {
      note: "The pill at the composer's start edge, 12px in.",
      snapshot,
      display: display(),
      play: park(),
      ...arm("center", "start"),
    },
    "pill-quiet": {
      note: "The pill at the end edge with no glass slab: chevron and count in muted ink in the gap of the line.",
      snapshot,
      display: display(),
      play: park(),
      ...arm("center", "quiet"),
    },
    "pill-middle": {
      note: "Before #48658 (Leo's 2026-11-21 screenshot): both on the center line, the disc right over the pill.",
      snapshot,
      display: display(),
      play: park(),
      ...arm("center", "middle"),
    },
    "pill-end-128": {
      note: '128 running: the pill reads "^ 128" and widens to the left, its end corner holding; the disc stays put.',
      snapshot: crowded,
      display: display(),
      play: park(),
      ...arm("center", "end"),
    },
    "pill-handle-left": {
      note: "The person put the handle at the left (agentPane.display.trayHandle): it stays there.",
      snapshot,
      display: display({ handle: "left" }),
      play: park({ handle: "left" }),
      ...arm("center", "end"),
    },
    "pill-hat-open": {
      note: "The hat open: the disc stands over the hat's middle; the hat's tuck chevron is at the end, where the pill will be.",
      snapshot,
      display: display({ tucked: false }),
      play: park({ tucked: false }),
      ...arm("center", "end"),
    },
    "pill-session-info-push": {
      note: "Session Info pushes (wide): the disc keeps the card's center and the pill its end edge.",
      snapshot,
      display: display(),
      play: park({ info: "push" }),
      ...arm("center", "end"),
    },
    end: {
      note: "#48658 (2026-11-21): the stack at the card's end edge, over its last button; the hat's pill alone in the middle. Leo, 2026-11-22: \"why'd the jump to bottom move to the right\".",
      snapshot,
      display: display(),
      play: park(),
      ...arm("end"),
    },
    start: {
      note: "Start edge: over the attach button's column, the pill alone in the middle.",
      snapshot,
      display: display(),
      play: park(),
      ...arm("start"),
    },
    corner: {
      note: "End corner: tucked against the card's end edge, a step lower, still a gap clear of its top line.",
      snapshot,
      display: display(),
      play: park(),
      ...arm("corner"),
    },
    "end-handle-right": {
      note: "The hat's handle at the right (agentPane.display.trayHandle): the end arm takes the start side so it never stands on the pill.",
      snapshot,
      display: display({ handle: "right" }),
      play: park({ handle: "right" }),
      ...arm("end"),
    },
    "start-handle-left": {
      note: "The hat's handle at the left: the start arm takes the end side.",
      snapshot,
      display: display({ handle: "left" }),
      play: park({ handle: "left" }),
      ...arm("start"),
    },
    "end-hat-open": {
      note: "The hat not tucked: the running tray stands over the composer, and the end arm's stack stands above its end corner.",
      snapshot,
      display: display({ tucked: false }),
      play: park({ tucked: false }),
      ...arm("end"),
    },
    "end-session-info-push": {
      note: "Session Info pushes (wide): the column moves left and the stack stays on the card's end edge.",
      snapshot,
      display: display(),
      play: park({ info: "push" }),
      ...arm("end"),
    },
  },
});
