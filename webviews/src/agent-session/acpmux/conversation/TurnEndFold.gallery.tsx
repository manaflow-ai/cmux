// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A turn's work stays in sight while the turn runs and folds once, in one motion, when it ends (Leo,
// 2026-11-08: "while you're working on stuff, you expose it. You show it ... and you only do the
// overarching fold at the very end"). Run the turn: its calls arrive one by one, each in sight, a
// short note between two runs on its own row; then the answer lands and the work folds under
// "Worked for" on the house settle (turnEndFold.ts). The arms compare how the rows that fold go
// (`data-turn-end-fold`): `wipe` (the fold matrix's pick, scripts/fold-matrix.ts) slides nothing:
// an edge runs down from the Worked for line, the new frame above it and the old below; `snapshot`
// cross-dissolves the two frames in place; `fade`, shipped, fades each where it was while the answer and the rows
// above slide to the folded line; `tuck` slides them up under the line as they fade; `stagger` fades
// them from the last up. `live` stops before the end: the work in sight, nothing folded. The `-long`
// states run a longer turn (a third run of calls) whose fold moves the answer far: it still ends with
// the settle's 180 ms, its curve flattened toward the straight line (turnEndFold.ts
// `turnEndFoldTiming`), and nothing is drawn back as the curve changes. The `lead-*` arms compare the
// exit before the move (exitLead.ts, design/chat-fold-motion.md; Leo, 2026-11-21: "we must hide text
// faster and sooner"): `lead-none`, before, the copies fading on the move's own clock; `fade` is the
// shipped 40 ms lead; `lead-quick`, a whole quick step of lead.
// The variants for Leo's "gash" (2026-11-22: "the big fold we do for claude is not good looking enough. it
// looks like a gash collapsing. you need to figure out more and more variations to deal with things."):
// `crossfade`, `morph`, `cascade`, `glide`, `spring`, `wait` and `dissolve` (turnEndFold.ts `TurnEndLook`),
// each short and `-long`; the motion-path looks `sheet`, `capped`, `viscous`, `water`, `edge` and `anchored` the same way. The dev setting `turn-end-fold-look` picks one in the running pane;
// scripts/fold-variants-record.ts records and measures each in the big Claude turn.
// The `steer-*` states end a turn whose reply the person steered just before it ended (Leo, 2026-11-25:
// "worked for above my message and then yours and then boom that's it", then "the final ultra fold
// simply... takes it all away. we simply need to make sure it looks good while doing so. aka fast fades and
// comfy (maybe eased) and fast and snappy and satisfying transition animations"): the fold pulls the work
// across the steer into the one Worked for, and the reply lands under the steer. The arms are its timing
// (`data-turn-end-cross`, turnEndFold.ts `CROSS_TIMING`): `steer-snap`, before, draws the end at once;
// `steer-quick`, shipped, fades in 120 ms and moves in 180; `steer-even` 140/200; `steer-eased` 160/220 on
// an in-out curve.
import { useEffect, useMemo, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnView } from "./turns";
import type { ExitLeadLook } from "./exitLead";
import type { TurnEndCross, TurnEndLook } from "./turnEndFold";

type Variant = TurnEndLook | "live";

const NOW = Date.UTC(2026, 10, 8, 2, 0, 0);
const at = (seconds: number) => NOW - 300_000 + seconds * 1000;

const command = (id: string, description: string, text: string): AcpmuxActivity => ({
  kind: "tool",
  text,
  tool: {
    id,
    title: text,
    kind: "execute",
    status: "completed",
    description,
    command: text,
    exitCode: 0,
    output: "ok\n",
  },
});
const read = (id: string, path: string): AcpmuxActivity => ({
  kind: "tool",
  text: `Read ${path}`,
  tool: { id, title: `Read ${path}`, kind: "read", status: "completed", locations: [{ path }] },
});

const FIRST: AcpmuxActivity[] = [
  command("fold-c1", "Pulled the latest changes", "git pull -q --ff-only"),
  read("fold-r1", "src/net/retry.ts"),
  command("fold-c2", "Ran the retry tests", "bun test test/retry.test.ts"),
  command("fold-c3", "Showed the failing case", "bun test test/retry.test.ts -t jitter"),
];
const SECOND: AcpmuxActivity[] = [
  read("fold-r2", "src/net/backoff.ts"),
  command("fold-c4", "Ran the whole suite", "bun test test/net"),
  command("fold-c5", "Checked the types", "bunx tsc --noEmit -p ."),
];

/// The long turn's third run: enough work that its fold moves the answer far.
const THIRD: AcpmuxActivity[] = [
  read("fold-r3", "src/net/jitter.ts"),
  command("fold-c6", "Ran the jitter case again", "bun test test/retry.test.ts -t jitter"),
  read("fold-r4", "test/retry.test.ts"),
  command("fold-c7", "Ran the retry tests again", "bun test test/retry.test.ts"),
  command("fold-c8", "Ran the whole suite again", "bun test test/net"),
  command("fold-c9", "Checked the types again", "bunx tsc --noEmit -p ."),
];

/// The chat's earlier turns, so the folded turn sits low in a view that scrolls.
const HISTORY: AcpmuxRow[] = Array.from({ length: 4 }, (_, index) => [
  {
    id: `fold-history-user-${index}`,
    kind: "user",
    version: 1,
    at: at(index * 10),
    text: `Earlier question ${index + 1}`,
  },
  {
    id: `fold-history-answer-${index}`,
    kind: "assistant",
    version: 1,
    at: at(index * 10 + 5),
    text: `Earlier answer ${index + 1}: the retry waits a little longer each time and adds a random jitter.`,
  },
  { id: `fold-history-summary-${index}`, kind: "turnSummary", version: 1, at: at(index * 10 + 6), durationMs: 6_000 },
]).flat();

/// The turn after `steps` of its calls, and whether it ended.
function turnRows(steps: number, ended: boolean, long = false, steered = false): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [
    ...HISTORY,
    { id: "fold-user", kind: "user", version: 1, at: at(60), text: "Fix the flaky retry test" },
  ];
  const first = FIRST.slice(0, steps);
  if (first.length)
    rows.push({
      id: "fold-run-1",
      kind: "activity",
      version: first.length,
      at: at(61),
      items: first,
      toolCount: first.length,
    });
  if (steps > FIRST.length)
    rows.push({
      id: "fold-note",
      kind: "assistant",
      version: 1,
      at: at(70),
      text: "The jitter case fails; checking the backoff next.",
    });
  const second = SECOND.slice(0, Math.max(0, steps - FIRST.length));
  if (second.length)
    rows.push({
      id: "fold-run-2",
      kind: "activity",
      version: second.length,
      at: at(71),
      items: second,
      toolCount: second.length,
    });
  const third = long ? THIRD.slice(0, Math.max(0, steps - FIRST.length - SECOND.length)) : [];
  if (third.length)
    rows.push({
      id: "fold-run-3",
      kind: "activity",
      version: third.length,
      at: at(80),
      items: third,
      toolCount: third.length,
    });
  // A steered turn's reply streams under its work, and the person's steer lands under it as it ends.
  if (steered && steps >= FIRST.length + SECOND.length)
    rows.push(
      {
        id: "fold-answer",
        kind: "assistant",
        version: 1,
        at: at(88),
        text: "Fixed: the jitter now stays inside the backoff's cap, and the suite passes.",
      },
      { id: "fold-steer", kind: "user", version: 1, at: at(89), text: "also run it 50 times", steer: "landed" },
    );
  if (ended && steered)
    rows.push({
      id: "fold-summary",
      kind: "turnSummary",
      version: 1,
      at: at(91),
      status: "completed",
      durationMs: 31_000,
      toolCount: 7,
    });
  else if (ended)
    rows.push(
      {
        id: "fold-answer",
        kind: "assistant",
        version: 1,
        at: at(90),
        text: "Fixed: the jitter now stays inside the backoff's cap, and the suite passes.",
      },
      {
        id: "fold-summary",
        kind: "turnSummary",
        version: 1,
        at: at(91),
        status: "completed",
        durationMs: 31_000,
        toolCount: long ? 7 + THIRD.length : 7,
      },
    );
  return rows;
}

const STEPS = FIRST.length + SECOND.length;

function TurnEndFoldGallery({
  variant,
  long = false,
  lead,
  steered = false,
  cross,
}: {
  variant: Variant;
  long?: boolean;
  lead?: ExitLeadLook;
  steered?: boolean;
  cross?: TurnEndCross;
}) {
  const turnSteps = long ? STEPS + THIRD.length : STEPS;
  const [steps, setSteps] = useState(0);
  const [ended, setEnded] = useState(false);
  const [state, setState] = useState<"ready" | "running" | "folded">("ready");
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach((timer) => window.clearTimeout(timer)), []);
  const rows = useMemo(
    () =>
      turnView(turnRows(steps, ended, long, steered), new Set(), {
        working: state === "running" && !ended,
        agentFamily: "claude",
        now: at(95),
      }),
    [steps, ended, state, long, steered],
  );
  // gallery-capture: runs only from Run the turn, which each arm's play clicks and then waits for its end state.
  const start = () => {
    timers.current.forEach((timer) => window.clearTimeout(timer));
    // The long turn starts with its first two runs done and plays only the third, so it ends as soon as
    // the short one (gallery health's ready-time budget) and folds the whole turn's work: the long move.
    const done = long ? STEPS : 0;
    const played = turnSteps - done;
    setEnded(false);
    setSteps(done);
    setState("running");
    for (let step = done + 1; step <= turnSteps; step += 1)
      timers.current.push(window.setTimeout(() => setSteps(step), (step - done) * 140));
    if (variant === "live") return;
    timers.current.push(window.setTimeout(() => setEnded(true), (played + 2) * 140));
    // The fold plays on the house settle (180 ms, a long move too); the line reads done once it has.
    timers.current.push(window.setTimeout(() => setState("folded"), (played + 2) * 140 + 800));
  };
  return (
    <div
      className="acpmux-shell"
      data-turn-end-fold={variant === "live" ? undefined : variant}
      data-exit-lead={lead}
      data-turn-end-cross={cross}
      style={{ height: "100%" }}
    >
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="turn-end-start" onClick={start}>
              Run the turn
            </button>
            <output data-testid="turn-end-state" aria-live="polite">
              {state === "folded" ? "Turn folded" : state === "running" ? `Step ${steps}` : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={rows}
            sessionId="turn-end-fold"
            onToggleActivity={() => {}}
            expanded={new Set()}
            working={state === "running" && !ended}
          />
        </div>
      </div>
    </div>
  );
}

/// Runs the turn to its end and waits for the fold.
const runToFold: Play = async (ctx) => {
  await ctx.click({ testId: "turn-end-start" });
  await ctx.waitFor(() => ctx.find({ testId: "turn-end-state" }).textContent === "Turn folded", { capMs: 5_000 });
};

/// Runs the turn's calls and stops before its end: each one in sight.
const runLive: Play = async (ctx) => {
  await ctx.click({ testId: "turn-end-start" });
  await ctx.waitFor(() => ctx.find({ testId: "turn-end-state" }).textContent === `Step ${STEPS}`, { capMs: 4_000 });
};

export default componentEntry<{
  variant: Variant;
  long?: boolean;
  lead?: ExitLeadLook;
  steered?: boolean;
  cross?: TurnEndCross;
}>({
  id: "agent-pane.turn-end-fold",
  title: "Turn end fold",
  area: "Agent pane",
  height: 560,
  anchors: [{ selector: "[data-testid=turn-end-start]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The turn's rows must not move the fixed control." },
    settleMaxMs: { value: 5_000, reason: "The deterministic turn runs for about two seconds." },
  },
  covers: [
    "agent-session/acpmux/conversation/turnEndFold.ts#playTurnEnd",
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
  ],
  load: async () => TurnEndFoldGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../composerControls.css"),
    ]),
  variants: {
    fade: { props: { variant: "fade" }, play: runToFold },
    tuck: { props: { variant: "tuck" }, play: runToFold },
    stagger: { props: { variant: "stagger" }, play: runToFold },
    live: { props: { variant: "live" }, play: runLive },
    "fade-long": { props: { variant: "fade", long: true }, play: runToFold },
    "tuck-long": { props: { variant: "tuck", long: true }, play: runToFold },
    "stagger-long": { props: { variant: "stagger", long: true }, play: runToFold },
    "lead-none": { props: { variant: "fade", lead: "none" }, play: runToFold },
    "lead-quick": { props: { variant: "fade", lead: "quick" }, play: runToFold },
    "lead-none-long": { props: { variant: "fade", long: true, lead: "none" }, play: runToFold },
    crossfade: { props: { variant: "crossfade" }, play: runToFold },
    "crossfade-long": { props: { variant: "crossfade", long: true }, play: runToFold },
    morph: { props: { variant: "morph" }, play: runToFold },
    "morph-long": { props: { variant: "morph", long: true }, play: runToFold },
    cascade: { props: { variant: "cascade" }, play: runToFold },
    "cascade-long": { props: { variant: "cascade", long: true }, play: runToFold },
    glide: { props: { variant: "glide" }, play: runToFold },
    "glide-long": { props: { variant: "glide", long: true }, play: runToFold },
    spring: { props: { variant: "spring" }, play: runToFold },
    "spring-long": { props: { variant: "spring", long: true }, play: runToFold },
    wait: { props: { variant: "wait" }, play: runToFold },
    "wait-long": { props: { variant: "wait", long: true }, play: runToFold },
    dissolve: { props: { variant: "dissolve" }, play: runToFold },
    "dissolve-long": { props: { variant: "dissolve", long: true }, play: runToFold },
    sheet: { props: { variant: "sheet" }, play: runToFold },
    "sheet-long": { props: { variant: "sheet", long: true }, play: runToFold },
    capped: { props: { variant: "capped" }, play: runToFold },
    "capped-long": { props: { variant: "capped", long: true }, play: runToFold },
    viscous: { props: { variant: "viscous" }, play: runToFold },
    "viscous-long": { props: { variant: "viscous", long: true }, play: runToFold },
    water: { props: { variant: "water" }, play: runToFold },
    "water-long": { props: { variant: "water", long: true }, play: runToFold },
    edge: { props: { variant: "edge" }, play: runToFold },
    "edge-long": { props: { variant: "edge", long: true }, play: runToFold },
    anchored: { props: { variant: "anchored" }, play: runToFold },
    "anchored-long": { props: { variant: "anchored", long: true }, play: runToFold },
    wipe: { props: { variant: "wipe" }, play: runToFold },
    "wipe-long": { props: { variant: "wipe", long: true }, play: runToFold },
    snapshot: { props: { variant: "snapshot" }, play: runToFold },
    "snapshot-long": { props: { variant: "snapshot", long: true }, play: runToFold },
    "steer-snap": { props: { variant: "fade", steered: true, cross: "snap" }, play: runToFold },
    "steer-quick": { props: { variant: "fade", steered: true, cross: "quick" }, play: runToFold },
    "steer-even": { props: { variant: "fade", steered: true, cross: "even" }, play: runToFold },
    "steer-eased": { props: { variant: "fade", steered: true, cross: "eased" }, play: runToFold },
  },
});
