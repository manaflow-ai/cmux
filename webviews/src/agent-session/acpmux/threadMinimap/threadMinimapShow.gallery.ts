// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// What the prompt rail shows (railShow.ts; Leo, 2026-11-21: "left side scroll prompt rail shows your
// prompts. why cant you see an agents'? why cant you filter it? customize it immediately? you should.
// we need to pursue this in an elegant and unobtrusive and cohesive way. debate on the appearance").
// Three designs for the agent's replies (replies.experiment.ts): `lens` (one list at a time, every tick
// alike, named by a control at the rail's head), `ruler` (replies as minor ticks between the prompts)
// and `lanes` (replies in an inner lane). Compare each showing prompts and replies, then the head
// control, its menu, and the lens on the turns with edits, errors and subagents.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { RAIL_CONTROL_KEY, RAIL_SHOW_KEY } from "./railShow";

const TOTAL = 28;
const subagent = (n: number): Subagent => ({
  id: `rail-show-subagent-${n}`,
  parent: null,
  name: `Review part ${n}`,
  task: `Review part ${n}`,
  prompt: `Review part ${n} of the rollout.`,
  state: "completed",
  startedAt: minutesAgo(300 - n * 2),
  endedAt: minutesAgo(300 - n * 2 - 0.5),
  result: `Part ${n} reviewed.`,
});
/// Twenty-eight turns: every fourth edits a file, every seventh fails, every fifth starts a subagent.
const rows: AcpmuxRow[] = Array.from({ length: TOTAL }, (_, index) => {
  const n = index + 1;
  const at = 300 - n * 2;
  const turn: AcpmuxRow[] = [{ ...user(`Prompt ${n}: inspect the next part of the rollout`, at), id: `user-${n}` }];
  if (n % 4 === 0)
    turn.push(
      activity(
        [
          tool(`Edit src/rollout/part${n}.ts`, "edit", "completed", {
            diffs: [{ path: `src/rollout/part${n}.ts`, newText: "ok" }],
          }),
        ],
        at + 0.1,
      ),
    );
  if (n % 5 === 0) turn.push(row(SUBAGENTS, at + 0.15, { id: `rail-show-group-${n}`, subagents: [subagent(n)] }));
  turn.push({ ...assistant(`Step ${n} checked.\n\nThe reply stays in the transcript.`, at + 0.2), id: `reply-${n}` });
  turn.push(summary(at + 0.4, { status: n % 7 === 0 ? "failed" : "completed", toolCount: n % 4 === 0 ? 1 : 0 }));
  return turn;
}).flat();
const snapshot = (title: string) => chat(rows, { title });

const hoverRail: Play = async (ctx) => {
  await ctx.hover({ selector: ".acpmux-minimap__list" });
};
const openControl: Play = async (ctx) => {
  await ctx.hover({ selector: ".acpmux-minimap__list" });
  await ctx.click({ selector: ".acpmux-minimap__show" });
};
const rightClick: Play = async (ctx) => ctx.contextMenu({ selector: ".acpmux-minimap__list" });

const show = (value: string, control = true) => ({
  [RAIL_SHOW_KEY]: value,
  ...(control ? { [RAIL_CONTROL_KEY]: true } : {}),
});

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-show",
  title: "Thread minimap: what the rail shows, and how replies draw",
  area: "Agent pane",
  height: 720,
  widths: { normal: 1040 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: [
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
    "agent-session/acpmux/threadMinimap/RailShowControl.tsx#RailShowControl",
  ],
  variants: {
    "default-unchanged": {
      note: "The default: every prompt, no head control, exactly as before (the menu is the only change).",
      snapshot: snapshot("Rail: default"),
    },
    "lens-everything": {
      note: "Lens: prompts and replies, every tick alike in one column; hovering shows the head control, Everything.",
      snapshot: snapshot("Rail: lens, everything"),
      experiments: { "thread-minimap-replies": "lens" },
      display: show("everything"),
      play: hoverRail,
    },
    "ruler-everything": {
      note: "Ruler: replies as shorter, dimmer minor ticks between the prompts they answer; no head control.",
      snapshot: snapshot("Rail: ruler, everything"),
      experiments: { "thread-minimap-replies": "ruler" },
      display: show("everything", false),
      play: hoverRail,
    },
    "lanes-everything": {
      note: "Lanes: replies set 8 px in, in an inner lane, with the head control.",
      snapshot: snapshot("Rail: lanes, everything"),
      experiments: { "thread-minimap-replies": "lanes" },
      display: show("everything"),
      play: hoverRail,
    },
    "lens-replies": {
      note: "Lens on the agent's replies only: one tick per reply, each landing on the reply.",
      snapshot: snapshot("Rail: replies"),
      experiments: { "thread-minimap-replies": "lens" },
      display: show("replies"),
    },
    "lens-edits": {
      note: "Lens on the turns that edited files (every fourth): the rail names Edits at rest, faintly.",
      snapshot: snapshot("Rail: edits"),
      experiments: { "thread-minimap-replies": "lens" },
      display: show("edits"),
    },
    "lens-errors": {
      note: "Lens on the turns that failed (every seventh).",
      snapshot: snapshot("Rail: errors"),
      experiments: { "thread-minimap-replies": "lens" },
      display: show("errors"),
    },
    "control-menu": {
      note: "The head control opened: the same choices as the right-click menu, the one on checked; empty ones disabled.",
      snapshot: snapshot("Rail: control menu"),
      experiments: { "thread-minimap-replies": "lens" },
      display: show("subagents"),
      play: openControl,
    },
    "right-click": {
      note: "Right-click: every choice, then Move to Right Edge; choosing one changes every rail at once.",
      snapshot: snapshot("Rail: right-click"),
      play: rightClick,
    },
  },
});
