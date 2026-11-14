// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A closed "Ran N commands" line at the very bottom of a chat, for N = 5, 20 and 100 (Leo,
// 2026-11-06: "The tool call expansion, when it has several tool calls, I think sometimes it lags a
// bit"). Opening it costs the same at any N: the rows the view shows draw in the click's frame, the
// rest after the fold (ToolGroupRow.tsx `StepList`), under a box already as tall as all of them.
// test/tool-group-expand-cost.test.ts measures click to fully opened frame on these.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, activity, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";
import { stepProbe } from "./toolGroupRowModel";
import type { Play } from "../../../gallery/play";
import { pinnedVariants } from "./pinnedToolRowsScenes";

const log = Array.from({ length: 6 }, (_, index) => `ok ${index + 1} - fetch retries case ${index + 1}`).join("\n");

const command = (index: number) =>
  tool(`bun test fetch --case ${index + 1}`, "execute", "completed", {
    command: `bun test fetch --case ${index + 1}`,
    description: `Run fetch case ${index + 1}`,
    output: log,
    exitCode: 0,
  });

const earlier = Array.from({ length: 4 }, (_, index) => {
  const minutes = 60 - index * 8;
  return [
    user(`Check part ${index + 1} of the retry loop`, minutes),
    assistant(
      `Part ${index + 1}. The fetch helper retries every failure the same way, so a 404 waits through three ` +
        "backoffs before it fails. I read how the helper decides to retry and who calls it.",
      minutes - 1,
    ),
  ];
}).flat();

const GROUP = '[data-row-id="tool-group-size-run"] button[data-tool-group]';

const rows = (n: number, items: AcpmuxActivity[] = Array.from({ length: n }, (_, index) => command(index))) => [
  ...earlier,
  user("Run every fetch case on its own", 6),
  activity(items, 5, { id: "tool-group-size-run" }),
  assistant(`All ${n} fetch cases pass.`, 4),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: n }),
];

/// The thought that led into the run, drawn in full at its head: many lines, far taller than a step.
const lead = thought(
  Array.from(
    { length: 6 },
    (_, index) =>
      `Part ${index + 1}: each fetch case runs on its own so a failure names its case. The helper ` +
      "retries every failure the same way, so a client error waits through three backoffs before it fails.",
  ).join("\n\n"),
  { startedAt: 1_000, endedAt: 7_000 },
);

const failed = (index: number) =>
  tool(`bun test fetch --case ${index + 1}`, "execute", "failed", {
    command: `bun test fetch --case ${index + 1}`,
    description: `Run fetch case ${index + 1}`,
    output: `${log}\nnot ok ${index + 1} - fetch retries case ${index + 1}\nerror: expected 404, got timeout`,
    exitCode: 1,
  });

/// 100 commands of mixed heights: the lead thought, a failure every fifth step and a later thought
/// every ninth.
const mixedCommands: AcpmuxActivity[] = [
  lead,
  ...Array.from({ length: 99 }, (_, index) =>
    index % 9 === 4
      ? thought(`Case ${index + 1} needs its fixture first.`)
      : index % 5 === 2
        ? failed(index)
        : command(index),
  ),
];

const CAPTURE =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// 100 reads of mixed heights: the lead thought, a read with an image every sixth step and a later
/// thought every eleventh.
const mixedReads: AcpmuxActivity[] = [
  lead,
  ...Array.from({ length: 99 }, (_, index) =>
    index % 11 === 5
      ? thought(`File ${index + 1} imports the helper.`)
      : tool(`Read capture-${index + 1}.png`, "read", "completed", {
          output: `Read capture ${index + 1}`,
          ...(index % 6 === 3 ? { images: [CAPTURE] } : {}),
        }),
  ),
];

declare global {
  interface Window {
    /** The scene's hold on an opened run's deferred row draws (ToolGroupRow.tsx `stepProbe.hold`). */
    cmuxStepDraws?: { held: (() => void)[]; hold: (on: boolean) => void };
  }
}

/// Opens the turn's "Worked for" line (a finished turn folds its run under it), then puts the view
/// at the transcript's very bottom, as the reader leaves it after reading the reply.
const atBottom: Play = async (ctx) => {
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  const group = () => ctx.document.querySelector(GROUP);
  await ctx.waitFor(() => worked() ?? group(), { capMs: 10_000 });
  if (!group() && worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(group, { capMs: 10_000 });
  }
  // As the reader's wheel does: it lets go of the line the Worked for click held.
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return;
  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
  scroller.scrollTop = scroller.scrollHeight;
  scroller.dispatchEvent(new Event("scroll"));
  // A test holds the rows an opened run draws after its fold, to look at the page between draws.
  const held: (() => void)[] = [];
  ctx.document.defaultView!.cmuxStepDraws = {
    held,
    hold: (on) => {
      stepProbe.hold = on ? (draw) => void held.push(draw) : undefined;
    },
  };
};

const variant = (n: number) => ({
  note: `Scrolled to the very bottom with “Ran ${n} commands” closed. Opening it draws the rows in view at once and the rest after the fold, under a box as tall as all of them.`,
  snapshot: chat(rows(n), { title: "Fetch cases" }),
  play: atBottom,
});

const mixed = (what: string, items: AcpmuxActivity[]) => ({
  note: `Scrolled to the very bottom with a closed run of 100 ${what} of mixed heights (a long lead thought, failures, later thoughts, images). Opened, the rows drawn after the fold take their own heights and nothing in view moves.`,
  snapshot: chat(rows(100, items), { title: "Fetch cases" }),
  play: atBottom,
});

export default agentPaneEntry({
  id: "agent-pane.tool-group-size",
  title: "Opening a long run of commands",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/ToolGroupRow.tsx#ToolGroupRow",
    "agent-session/acpmux/conversation/KeepOpenedLine.tsx#KeepOpenedLine",
  ],
  variants: {
    n5: variant(5),
    n20: variant(20),
    n100: variant(100),
    "mixed-commands": mixed("commands", mixedCommands),
    "mixed-reads": mixed("reads", mixedReads),
    // An opened call stays open and in place when the next call regroups the run (pinnedToolRowsScenes.ts).
    ...pinnedVariants,
  },
});
