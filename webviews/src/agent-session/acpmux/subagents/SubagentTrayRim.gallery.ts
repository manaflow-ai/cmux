// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's top rim drags (trayResize.ts). Leo, 2026-11-12: "it's sort of weird how, you
// know, you have this glass rim, but you can't drag up the composer hat area ... why are there
// ellipses going so fast? Like they get truncated and cut off so soon." Compare the default five
// lines with the list dragged taller and shorter; the long commands run to the row's edge.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { setHatHeight } from "./trayResize";
import { RUNNING_TRAY_LIST_LINE } from "./subagentSelectors";

const running = (task: string, minutes: number, action: string): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const snapshot = chat([
  user("Keep the waits going and fan the reviews out", 14),
  row(SUBAGENTS, 14, {
    subagents: [
      running("Review the fold", 6, "cd webviews && bun test src/agent-session/acpmux/subagents/subagentFold.test.ts"),
      running("Read the bottom stack", 5, "Grep acpmux-running-tray__list webviews/src/agent-session/acpmux"),
      running("Audit the linger", 3, "Read trayLinger.ts"),
    ],
  }),
  activity(
    [
      command("gh run watch 19283746 --repo acme/app --exit-status --interval 30 --compact", "wait for CI", 12),
      command("gh pr checks 41790 --repo acme/app --watch --fail-fast --interval 30", "wait for merge", 10),
      command("bun test webviews/src/agent-session/acpmux/subagents --timeout 30000", "run the hat tests", 9),
      command("cd ~/Projects/app && bun run dev --port 5173", "Run the dev server", 8),
    ],
    13,
  ),
  assistant("The waits and the reviewers keep running in the background.", 1),
  summary(1, { status: "completed", durationMs: 600_000, toolCount: 7 }),
]);

// Eight running reviewers, so a drag has lines to move through both ways.
const many = chat([
  user("Fan eight reviews out and keep them going", 9),
  row(SUBAGENTS, 9, {
    subagents: [
      "Review the fold",
      "Read the bottom stack",
      "Audit the linger",
      "Check the rim's detents",
      "Time the open motion",
      "Read the tuck tab",
      "Count the header kinds",
      "Check the scroll padding",
    ].map((task, i) => running(task, 8 - i, `Read file-${i + 1}.ts`)),
  }),
  assistant("Eight reviewers are running.", 1),
  summary(1, { status: "completed", durationMs: 480_000, toolCount: 8 }),
]);

const opened = (height: number | undefined) => async (ctx: PlayContext) => {
  setHatHeight(height, false);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  // The hat remembers its fold per chat, so a frame that shares storage with an earlier play can
  // start open; a click then would fold it. Open it only when it is folded.
  if (!ctx.document.querySelector(".acpmux-running-tray[data-open]"))
    await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(RUNNING_TRAY_LIST_LINE));
};
// Leo, 2026-11-22: "the dragging isn't properly relative accurate to the cursor, and it's just jumpy
// all over the place and doesn't have satisfying snap alongs. i also am not sure if clicking on the
// resizing area itself should necessarily hide it." These drive the rim with real pointer events in
// real layout and fail when the rim leaves the cursor, a release lands between lines, or a click moves it.
const rimNode = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__rim")!;
const rimTop = (ctx: PlayContext) => rimNode(ctx).getBoundingClientRect().top;
const listBox = (ctx: PlayContext) =>
  ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__list")?.getBoundingClientRect().height ?? 0;
const frames = (ctx: PlayContext, n = 2) =>
  new Promise<void>((resolve) => {
    const view = ctx.document.defaultView!;
    const step = (left: number) => (left === 0 ? resolve() : view.requestAnimationFrame(() => step(left - 1)));
    step(n);
  });
/// Waits until the hat stops moving (its open motion ends), so a drag measures from rest.
const settle = async (ctx: PlayContext) => {
  let last = Number.NaN;
  for (let still = 0, guard = 0; still < 6 && guard < 120; guard++) {
    await frames(ctx, 1);
    const now = rimTop(ctx) + listBox(ctx) * 1000;
    still = now === last ? still + 1 : 0;
    last = now;
  }
};
const fire = (ctx: PlayContext, type: string, y: number) => {
  const rim = rimNode(ctx);
  const x = rim.getBoundingClientRect().left + 40;
  const View = ctx.document.defaultView!;
  // A synthetic pointer has no browser pointer to capture, and the throw would end the press
  // handler early: it would hide what the press does after capture (on base, a forwarded click).
  rim.setPointerCapture = () => {};
  rim.dispatchEvent(
    new View.PointerEvent(type, {
      bubbles: true,
      cancelable: true,
      pointerId: 7,
      button: 0,
      buttons: 1,
      clientX: x,
      clientY: y,
    }),
  );
};
/// Presses the rim 4px under its top, moves through `path` (px above the press), and lets go at the
/// last point unless `hold`. Returns the worst gap between where the rim is and where the cursor put it,
/// away from a line's edge (where it settles on purpose) and past the last line (where it gives).
const drag = async (ctx: PlayContext, path: number[], hold = false) => {
  await settle(ctx);
  const grabY = rimTop(ctx) + 4;
  const startTop = rimTop(ctx);
  const startList = listBox(ctx);
  const natural = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__list")?.scrollHeight ?? 0;
  fire(ctx, "pointerdown", grabY);
  let worst = 0;
  for (const grown of path) {
    fire(ctx, "pointermove", grabY - grown);
    await frames(ctx);
    const list = listBox(ctx);
    const settled = list !== Math.round(startList + grown) && Math.abs(list - (startList + grown)) <= 6;
    if (!settled && list > 4 && startList + grown < natural - 2)
      worst = Math.max(worst, Math.abs(startTop - grown - rimTop(ctx)));
  }
  if (!hold) {
    fire(ctx, "pointerup", grabY - (path.at(-1) ?? 0));
    await settle(ctx);
  }
  return worst;
};
const tracks = async (ctx: PlayContext) => {
  await opened(84)(ctx);
  const path = [1, 2, 3, 6, 11, 17, 23, 31, 38, 44, 37, 25, 12, -3, -12, -19, -27, -33];
  const worst = await drag(ctx, path, true);
  if (worst > 1) throw new Error(`the rim left the cursor by ${worst}px mid-drag`);
  ctx.document.documentElement.dataset.rimWorst = String(worst);
};
const landsOnLines = async (ctx: PlayContext) => {
  await opened(84)(ctx);
  await drag(ctx, [5, -10, -25, -38]);
  const list = listBox(ctx);
  // Dragged from three lines to 1.6 lines: it lands on two whole lines (56px and the list's 2px).
  if (Math.abs(list - 58) > 1) throw new Error(`released between lines: the list is ${list}px`);
};
const foldsAtHalf = async (ctx: PlayContext) => {
  await opened(84)(ctx);
  await drag(ctx, [-20, -50, -72]);
  if (ctx.document.querySelector(".acpmux-running-tray[data-open]"))
    throw new Error("under half a line it should fold");
};
const clickStays = async (ctx: PlayContext) => {
  await opened(84)(ctx);
  await settle(ctx);
  const before = { top: rimTop(ctx), list: listBox(ctx) };
  await drag(ctx, [1, -1, 2]);
  const after = { top: rimTop(ctx), list: listBox(ctx) };
  if (!ctx.document.querySelector(".acpmux-running-tray[data-open]"))
    throw new Error("a click on the rim folded the hat");
  if (before.top !== after.top || before.list !== after.list) throw new Error("a click on the rim moved the hat");
};

const rimHovered = async (ctx: PlayContext) => {
  await opened(undefined)(ctx);
  await ctx.hover({ selector: ".acpmux-running-tray__rim" });
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-rim",
  title: "Composer hat: drag the rim, lines cut at the row's edge",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayResize.ts",
    "agent-session/acpmux/subagents/trayDetail.ts",
  ],
  variants: {
    default: {
      note: "Open at the default five lines: each command runs to the row's edge before its ellipsis, never 40 characters in.",
      play: opened(undefined),
      snapshot,
    },
    rim: {
      note: "The pointer on the hat's top rim: the resize cursor; a drag up makes the list taller.",
      play: rimHovered,
      snapshot,
    },
    taller: {
      note: "Dragged up to 260px: every line shows, no scroll.",
      play: opened(260),
      snapshot,
    },
    "drag-tracks": {
      note: "Held mid-drag between two lines: the rim stays under the cursor 1:1 from where it was grabbed, up and back down (the play fails past 1px).",
      play: tracks,
      snapshot: many,
    },
    "drag-lands": {
      note: "Let go with 1.6 lines shown: it lands on two whole lines; a line more than half shown stays.",
      play: landsOnLines,
      snapshot: many,
    },
    "drag-folds": {
      note: "Let go with under half of the first line shown: the hat folds (the halfway point is one line's, not five's).",
      play: foldsAtHalf,
      snapshot: many,
    },
    "click-stays": {
      note: "A press on the rim that wobbles a pixel and lets go: nothing folds, opens or moves.",
      play: clickStays,
      snapshot: many,
    },
    shorter: {
      note: "Dragged down to two lines: the rest scroll in place.",
      play: opened(56),
      snapshot,
    },
  },
});
