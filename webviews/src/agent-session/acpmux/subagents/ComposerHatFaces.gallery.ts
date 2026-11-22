// l10n-allow-file: gallery fixtures (prompts, subagent tasks), not shipped UI.
// The composer hat's folded header draws one icon per subagent (HatFaces.tsx). Leo, 2026-11-21: "i
// wanted those icons to be there. like before. then you can have your mouse hover across stuff."; and
// 2026-11-22, on a header of "7 subagents · 4 done · 1 stopped" that drew one mark and one tooltip:
// "i wanted the redesign to show a lot of icons (of subagents) and be able to thumb through them when
// my cursor is hovering over them to be able to parse who's who".
//
// Widths stand for his splits of a 1440 pt window: wide a half, normal a third, narrow a quarter.
// Variants hold 1, 3, 7 and 20 subagents; compare the arms (hatFaces.experiment.ts) with the entry's
// experiment. Each play crosses the row icon by icon and reads every tooltip in turn, then checks that
// a subagent finishing and one joining move nothing in the header.
import { agentPaneEntry } from "../../../gallery/format";
import { chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { hatFacesLook } from "./hatFaces.experiment";

const TASKS = [
  "Asks reconciler stale root fix",
  "Review the tray columns",
  "Port the history page to React Aria",
  "Bisect the flaky fold test",
  "Find the screenshot",
  "Measure the split layout shift",
  "Check the jump arrow placement",
  "Read the composer hat CSS",
  "Fix nightly guard base red",
  "Audit the tooltip delays",
  "Trace the subagent title fallback",
  "Port the picker to the shared composer",
  "Record the send animation",
  "Compare the stacked glass arms",
  "Grep the old marks",
  "Run the WebKit suite",
  "Write the gallery entry",
  "Check the iPhone parity row",
  "Read the review notes",
  "Land the opt-in arm",
];

/** Leo's header from the 2026-11-22 frames: 7 subagents, 4 done, 1 stopped, 2 running. */
const LEO_STATES: Subagent["state"][] = [
  "running",
  "completed",
  "completed",
  "running",
  "completed",
  "cancelled",
  "completed",
];

function agent(index: number, state: Subagent["state"]): Subagent {
  const task = TASKS[index % TASKS.length]!;
  return {
    id: `agent-face-${index}`,
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state,
    background: true,
    // Every third one is a Codex subagent, so the row shows marks of both families.
    ...(index % 3 === 2 ? { harness: "codex" } : {}),
    ...(state === "running" ? { startedAt: minutesAgo(80 - index) } : recentRun(40 - index, 12)),
  };
}

function snapshot(count: number) {
  const states: Subagent["state"][] = Array.from({ length: count }, (_, index) =>
    count === 7 ? LEO_STATES[index]! : index % 4 === 1 ? "completed" : "running",
  );
  return chat(
    [
      user("Fan out over the open asks and report back", 80),
      row(SUBAGENTS, 80, { subagents: states.map((state, index) => agent(index, state)) }),
    ],
    { isWorking: true },
  );
}

const faces = (ctx: PlayContext) => [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-hat-face")];
const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const tooltip = (ctx: PlayContext) =>
  ctx.document.querySelector<HTMLElement>(".ui-title-tooltip .ui-tooltip-text")?.textContent ?? "";

/** Crosses the row icon by icon: each names its own subagent at once. */
async function scrub(ctx: PlayContext): Promise<void> {
  await ctx.waitFor(() => head(ctx));
  const row = faces(ctx);
  if (row.length === 0) return; // the "lead" arm draws one mark, as before
  const seen: string[] = [];
  for (const face of row) {
    const name = face.getAttribute("aria-label")?.split(", ")[0] ?? "";
    await ctx.hover({ selector: `[data-hat-face="${face.dataset.hatFace}"]` });
    await ctx.waitFor(() => tooltip(ctx) === name);
    seen.push(name);
  }
  if (new Set(seen).size !== seen.length) throw new Error(`two icons named one subagent: ${seen.join(" | ")}`);
}

/** The header's words never move while the row is crossed. */
function wordsLeft(ctx: PlayContext): number {
  return ctx.document.querySelector(".acpmux-running-tray__kind")?.getBoundingClientRect().left ?? 0;
}

function variant(count: number, note: string) {
  return {
    note,
    snapshot: snapshot(count),
    play: async (ctx: PlayContext) => {
      await ctx.waitFor(() => head(ctx));
      const before = wordsLeft(ctx);
      await scrub(ctx);
      const after = wordsLeft(ctx);
      if (Math.abs(after - before) > 0.5) throw new Error(`the header's words moved ${after - before}px on hover`);
    },
  };
}

export default agentPaneEntry({
  id: "agent-pane.composer-hat-faces",
  title: "Composer hat: one icon per subagent, named on hover",
  area: "Agent pane",
  height: 260,
  widths: { narrow: 360, normal: 480, wide: 720 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/HatFaces.tsx", "agent-session/acpmux/subagents/SubagentTray.tsx"],
  experiment: {
    definition: hatFacesLook,
    script: [{ name: "cross the icons", run: (ctx) => scrub(ctx) }],
  },
  variants: {
    one: variant(1, "One subagent: the hat heads it as before, its mark and its task by name (no row of one)."),
    three: variant(3, "Three: side by side, each named in turn as the pointer crosses them."),
    "leo-seven": variant(
      7,
      'Leo\'s header (2026-11-22): "7 subagents · 4 done · 1 stopped". Seven icons, the ended ones dimmed; crossing them reads all seven names.',
    ),
    twenty: variant(
      20,
      "Twenty: they overlap evenly within the cap, each still a strip the pointer finds; on a quarter split the first eleven then +9.",
    ),
  },
});
