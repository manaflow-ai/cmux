// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A turn's work stays in sight while the turn runs and folds once, in one motion, when it ends (Leo,
// 2026-11-08: "while you're working on stuff, you expose it. You show it ... and you only do the
// overarching fold at the very end"). Run the turn: its calls arrive one by one, each in sight, a
// short note between two runs on its own row; then the answer lands and the work folds under
// "Worked for" on the house settle (turnEndFold.ts). The arms compare how the rows that fold go
// (`data-turn-end-fold`): `fade`, shipped, fades each where it was while the answer and the rows
// above slide to the folded line; `tuck` slides them up under the line as they fade; `stagger` fades
// them from the last up. `live` stops before the end: the work in sight, nothing folded. The `-long`
// states run a longer turn (a third run of calls) whose fold moves the answer far enough that the
// fold's clock grows past the settle's 180 ms (turnEndFold.ts `turnEndFoldTiming`): each frame keeps
// under 0.6 of a line, and nothing is drawn back as the clock grows.
import { useEffect, useMemo, useRef, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnView } from "./turns";
import type { TurnEndLook } from "./turnEndFold";

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
function turnRows(steps: number, ended: boolean, long = false): AcpmuxRow[] {
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
  if (ended)
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

function TurnEndFoldGallery({ variant, long = false }: { variant: Variant; long?: boolean }) {
  const turnSteps = long ? STEPS + THIRD.length : STEPS;
  const [steps, setSteps] = useState(0);
  const [ended, setEnded] = useState(false);
  const [state, setState] = useState<"ready" | "running" | "folded">("ready");
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach((timer) => window.clearTimeout(timer)), []);
  const rows = useMemo(
    () =>
      turnView(turnRows(steps, ended, long), new Set(), {
        working: state === "running" && !ended,
        agentFamily: "claude",
        now: at(95),
      }),
    [steps, ended, state, long],
  );
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
    // The fold plays on the house settle (180 ms, longer for a long move); the line reads done once it has.
    timers.current.push(window.setTimeout(() => setState("folded"), (played + 2) * 140 + 800));
  };
  return (
    <div
      className="acpmux-shell"
      data-turn-end-fold={variant === "live" ? undefined : variant}
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

export default componentEntry<{ variant: Variant; long?: boolean }>({
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
  },
});
