// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// Where the jump stack stands over the composer (jumpPlace.experiment.ts, jumpPlace.css, jumpPlace.ts,
// App.tsx `data-jump-place` / `data-jump-side`). Leo, 2026-11-21, of Jump to latest's disc standing
// right on the tucked hat's "^ 3" pill: "this is uncomfortably tight. didn't we say we wanted to move
// these to the side or smth?" Every variant is the conflict: a long transcript parked mid-chat so Jump
// to latest shows, and the composer hat tucked (agentPane.display.trayTucked) with three subagents
// running, so the pull tab reads "^ 3" in the composer's middle. `end` ships; `center` is the before.
// View at every width (narrow 420, normal 900, wide 1600); light and dark: ?colorScheme=light / dark.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
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
const snapshot = chat(
  [
    ...Array.from({ length: 24 }, (_, index) => [
      user(`Check retry case ${index + 1}`, 60 - index * 2),
      assistant(
        `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
          3,
        ),
        59 - index * 2,
      ),
      summary(59 - index * 2, { status: "completed" }),
    ]).flat(),
    user("Review the retry change from three sides", 6),
    row(SUBAGENTS, 5.5, {
      subagents: [running("Review the retry loop", 5), running("Review the tests", 5), running("Review the docs", 5)],
    }),
    assistant("Three reviewers are reading the change now.", 4),
  ],
  { isWorking: true },
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

const arm = (place: JumpLatestPlace) => ({ experiments: { [jumpLatestPlace.id]: place } });

export default agentPaneEntry({
  id: "agent-pane.jump-place",
  title: "Jump to latest beside the tucked composer hat",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: [
    "agent-session/acpmux/jumpPlace.css",
    "agent-session/acpmux/jumpPlace.experiment.ts",
    "agent-session/acpmux/jumpPlace.ts",
    "agent-session/acpmux/VirtualTranscript.tsx#JumpToLatest",
  ],
  keywords: ["jump to latest", "jump to bottom", "composer hat", "tray", "pull tab", "side"],
  checks: {
    anchorMovePx: { value: 0, reason: "Parking the reader moves only the transcript; the composer holds still." },
  },
  experiment: { definition: jumpLatestPlace, script: [{ name: "Park mid-chat, the hat tucked", run: park() }] },
  variants: {
    end: {
      note: "Selected (ships): the stack at the card's end edge, over its last button; the hat's \"^ 3\" pill stands alone in the middle.",
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
    center: {
      note: 'Before (Leo\'s screenshot): centered on the composer, the disc right on the "^ 3" pill.',
      snapshot,
      display: display(),
      play: park(),
      ...arm("center"),
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
