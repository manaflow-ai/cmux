// l10n-allow-file: test fixture chats, not shipped UI.
// The chat simulator's browser lane (src/agent-session/acpmux/sim/README.md): the same run as
// `bun scripts/chat-sim.ts` (the pane's reducer, turn view and layout on virtual time), drawn at every
// step by the real VirtualTranscript with the pane's CSS, and probed by the rows' drawn boxes
// (`.acpmux-row[data-row-id]`), so rule (a) reads the gaps the reader sees and rule (b) the folds the
// stack draws. `window.__chatSim.run(name)` plays a scenario (or `replay`, the sanitized fixture) and
// returns the result without its per-step trace (`traces` keeps the steps that broke a rule).
//
// The page's motion is off (`data-agent-motion=off`), so a box is where its row rests, not a frame of a
// move. `?width=` sets the pane's width (default 720). `?motion=on` leaves the pane's motion on, for
// `window.__chatSim.watch` (scripts/chat-sim-watch.ts): it plays a scenario, or records the page is
// handed (any fixture), on scaled real time, so a person (or a video) sees the chat stream and fold.
import { useLayoutEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { EventRecord } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { playbackAt, playbackWindow } from "../../src/agent-session/acpmux/sim/playback";
import { createSimulation, runSimulationAsync, type SimResult } from "../../src/agent-session/acpmux/sim/run";
import { watchChurn, type ChurnReport } from "./chatChurnWatch";
import { parseRecords } from "../../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, type SimScenario } from "../../src/agent-session/acpmux/sim/script";
import { SCENARIOS, longRun } from "../../src/agent-session/acpmux/sim/scenarios";
import { TRANSCRIPT_ROW } from "../../src/agent-session/acpmux/transcriptSelectors";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/markdownField.css";

const query = new URLSearchParams(location.search);
// `?motion=on` (the churn lane, `live`): the pane's own motion plays, as in the app.
if (query.get("motion") !== "on") {
  document.documentElement.dataset.agentMotion = "off";
  document.documentElement.dataset.cmuxMotion = "off";
}

type PaneState = { rows: readonly AcpmuxRow[]; working: boolean; sends: number };
let show: (next: PaneState) => void = () => {};
const expanded = new Set<string>();

function Pane() {
  const [state, setState] = useState<PaneState>({ rows: [], working: false, sends: 0 });
  // The page drives the pane through `show`; it is set after the first render, not during one.
  useLayoutEffect(() => {
    show = setState;
  }, []);
  return (
    <div className="acpmux-shell">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={state.rows as AcpmuxRow[]}
            sessionId="chat-sim"
            working={state.working}
            sends={state.sends}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
      </div>
    </div>
  );
}

const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));

/** Draws `rows` and reads each drawn row's box (undefined for a row the virtual stack did not draw). */
async function measure(rows: readonly AcpmuxRow[], working: boolean, sends: number) {
  flushSync(() => show({ rows, working, sends }));
  await frame();
  await frame();
  const boxes = new Map<string, { top: number; bottom: number }>();
  for (const element of document.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
    const rect = element.getBoundingClientRect();
    if (rect.height > 0) boxes.set(element.dataset.rowId!, { top: rect.top, bottom: rect.bottom });
  }
  return rows.map((row) => boxes.get(row.id));
}

async function scenarioNamed(name: string): Promise<SimScenario> {
  if (name === "replay") {
    const text = (await import("../fixtures/chat-sim/replay-lane-session.ndjson?raw")).default as string;
    return replayScenario("replay-lane-session", parseRecords(text));
  }
  // `file:PATH` (the churn lane): a recorded chat the dev server serves from under webviews/.
  if (name.startsWith("file:")) {
    const path = name.slice("file:".length);
    const text = await (await fetch(`/${path}`)).text();
    return replayScenario(path.replace(/^.*\//, "").replace(/\.ndjson$/, ""), parseRecords(text));
  }
  const long = /^long:(\d+)$/.exec(name);
  if (long) return longRun(Number(long[1]));
  const make = SCENARIOS[name];
  if (!make) throw new Error(`no scenario ${name}`);
  return make();
}

async function run(name: string): Promise<SimResult> {
  const scenario = await scenarioNamed(name);
  let sends = 0;
  let turn = 0;
  const result = await runSimulationAsync(
    scenario,
    (rows, _step, _index, state) => {
      // A new turn the reader opened scrolls to it, as a send does.
      if (state.turn !== turn) {
        turn = state.turn;
        sends += 1;
      }
      return measure(rows, state.working, sends);
    },
    { rowsInTraceUpTo: 0 },
  );
  return { ...result, traces: result.traces.filter((trace) => trace.violations.length) };
}

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, {
  height: "100%",
  width: `${Number(query.get("width")) || 720}px`,
  display: "flex",
  flexDirection: "column",
});
createRoot(root).render(<Pane />);
/** Each drawn row's box, its content's box (the union of its children's) and its padding, for a look at
 *  where a row's gap lives. */
function dump() {
  return [...document.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)].map((element) => {
    const rect = element.getBoundingClientRect();
    let top = Infinity;
    let bottom = -Infinity;
    for (const child of element.querySelectorAll<HTMLElement>("*")) {
      const box = child.getBoundingClientRect();
      if (box.height === 0 || !child.textContent?.trim()) continue;
      top = Math.min(top, box.top);
      bottom = Math.max(bottom, box.bottom);
    }
    const style = getComputedStyle(element);
    return {
      id: element.dataset.rowId,
      className: element.className,
      top: rect.top,
      bottom: rect.bottom,
      inkTop: top,
      inkBottom: bottom,
      text: element.innerText.replace(/\s+/g, " ").slice(0, 160),
      paddingTop: style.paddingTop,
      marginTop: style.marginTop,
    };
  });
}

/** Plays `name` up to step `until` and returns the drawn rows' dump there. */
async function at(name: string, until: number) {
  const scenario = await scenarioNamed(name);
  const cut = { ...scenario, steps: scenario.steps.slice(0, until + 1) };
  let sends = 0;
  let turn = 0;
  await runSimulationAsync(cut, (rows, _step, _index, state) => {
    if (state.turn !== turn) {
      turn = state.turn;
      sends += 1;
    }
    return measure(rows, state.working, sends);
  });
  return dump();
}

export type WatchOptions = {
  /** A scenario name (as `run` takes), unless `records` is given. */
  name?: string;
  /** Records to replay (a fixture the caller read), instead of a named scenario. */
  records?: EventRecord[];
  /** Virtual time runs this many times faster than real time (default 1). */
  speed?: number;
  /** The longest real wait between two steps, ms (default 1500): an idle hour does not play as one. */
  maxGapMs?: number;
  /** The shortest real wait between two steps, ms (default 16): a burst of records still draws frame by frame. */
  minGapMs?: number;
  /** Also call `onShot` every this many steps (0: only at turn boundaries and the end). */
  shotEvery?: number;
  /** Stop after this many seconds of real time. */
  maxSeconds?: number;
  /** Start the playback here, s of the full playback (as a whole run's video reads, at this speed and
   *  gap bound; `playbackAt`): the steps before it are drawn at once, then the view settles
   *  (WINDOW_SETTLE_MS) and `__chatSimWindow("start")` marks where the window's video begins. */
  startS?: number;
  /** Stop the playback here, s of the full playback (as startS). */
  endS?: number;
};

/** After the steps before a window are drawn at once, the view settles this long before the window plays. */
export const WINDOW_SETTLE_MS = 1500;

export type WatchShot = { step: number; label: string; why: "turn-start" | "turn-end" | "every" | "end"; turn: number };

/** What `watch` played. */
export type WatchResult = {
  scenario: string;
  steps: number;
  played: number;
  turns: number;
  shots: number;
  wallMs: number;
  virtualMs: number;
  stoppedEarly: boolean;
  violations: number;
};

// fixed-wait: watch and live play a scenario on real time (for a person, a video, or the churn lane's per-frame watcher); the wait is the playback.
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Plays a scenario on scaled real time with the pane's motion as the page has it, drawing each step
 *  as it comes. At turn starts and ends (and every `shotEvery` steps) it awaits `window.__chatSimShot`
 *  (the watch command's screenshot hook) when the page has one. */
async function watch(options: WatchOptions): Promise<WatchResult> {
  const started = performance.now();
  // The pane's words, as the app's page head loads them (the rule runs draw the keys, and keep doing so).
  const strings = (await import("../../src/agent-session/acpmux/generated/strings.json")).default;
  globalThis.__cmuxPaneStrings = { en: strings.en } as never;
  const { setPaneLanguage } = await import("../../src/agent-session/acpmux/i18n");
  setPaneLanguage("en");
  const scenario = options.records
    ? replayScenario(options.name ?? "records", options.records)
    : await scenarioNamed(options.name ?? "replay");
  const speed = options.speed && options.speed > 0 ? options.speed : 1;
  const maxGap = options.maxGapMs ?? 1500;
  const minGap = options.minGapMs ?? 16;
  const deadline = options.maxSeconds ? started + options.maxSeconds * 1000 : Number.POSITIVE_INFINITY;
  const shotHook = (window as unknown as { __chatSimShot?: (shot: WatchShot) => Promise<void> }).__chatSimShot;
  let shots = 0;
  const shoot = async (shot: WatchShot) => {
    if (!shotHook) return;
    shots += 1;
    await shotHook(shot);
  };
  const sim = createSimulation(scenario, { rowsInTraceUpTo: 0 });
  // The page's clock runs on the scenario's virtual time, so "Working for" and the elapsed counters read
  // the simulated time, not the hours since the scenario's recorded start.
  const realNow = Date.now.bind(Date);
  let virtualAt = scenario.steps[0]?.at ?? realNow();
  let realAt = performance.now();
  Date.now = () => Math.round(virtualAt + (performance.now() - realAt) * speed);
  let sends = 0;
  let turn = 0;
  let played = 0;
  let stoppedEarly = false;
  let lastAt = scenario.steps[0]?.at ?? 0;
  const playback = playbackAt(
    scenario.steps.map((step) => step.at),
    speed,
    minGap,
    maxGap,
  );
  const startMs = (options.startS ?? 0) * 1000;
  const endMs = options.endS === undefined ? Number.POSITIVE_INFINITY : options.endS * 1000;
  const windowHook = (window as unknown as { __chatSimWindow?: (mark: "start") => Promise<void> }).__chatSimWindow;
  // The steps before the window: drawn at once (the last of them shown), then the view settles.
  const { first, end } = playbackWindow(playback, startMs, endMs);
  if (first > 0) {
    let rows: ReturnType<typeof sim.advance> = undefined;
    for (let index = 0; index < first; index += 1) {
      const drawn = sim.advance(index);
      if (drawn) sim.check(index);
      rows = drawn ?? rows;
      played += 1;
    }
    lastAt = virtualAt = scenario.steps[first - 1]!.at;
    realAt = performance.now();
    const state = sim.state();
    turn = state.turn;
    sends = state.turn;
    if (rows) flushSync(() => show({ rows: rows!, working: state.working, sends }));
    // fixed-wait: the drawn-at-once history settles (its folds and follow) before the window plays.
    await sleep(WINDOW_SETTLE_MS);
  }
  if (windowHook) await windowHook("start");
  for (let index = first; index < scenario.steps.length; index += 1) {
    if (performance.now() > deadline || index >= end) {
      stoppedEarly = true;
      break;
    }
    const step = scenario.steps[index]!;
    // fixed-wait: the step's own (scaled) time since the step before: the playback's clock.
    await sleep(Math.min(maxGap, Math.max(minGap, (step.at - lastAt) / speed)));
    lastAt = step.at;
    virtualAt = step.at;
    realAt = performance.now();
    const wasEnded = sim.state().turnEnded;
    const rows = sim.advance(index);
    played += 1;
    if (!rows) continue;
    const state = sim.state();
    const opened = state.turn !== turn;
    if (opened) {
      turn = state.turn;
      sends += 1;
    }
    flushSync(() => show({ rows, working: state.working, sends }));
    sim.check(index);
    await frame();
    const shot = { step: index, label: step.label, turn: state.turn };
    if (opened) await shoot({ ...shot, why: "turn-start" });
    else if (state.turnEnded && !wasEnded) {
      // fixed-wait: let the turn's fold animation play out before the picture.
      await sleep(Math.min(1200, maxGap));
      await shoot({ ...shot, why: "turn-end" });
    } else if (options.shotEvery && index % options.shotEvery === 0 && index < scenario.steps.length - 1)
      await shoot({ ...shot, why: "every" });
  }
  // fixed-wait: let the last fold animation play out before the last picture.
  await sleep(Math.min(1200, maxGap));
  await shoot({ step: played - 1, label: "end", turn, why: "end" });
  Date.now = realNow;
  const result = sim.result();
  return {
    scenario: scenario.name,
    steps: scenario.steps.length,
    played,
    turns: turn,
    shots,
    wallMs: Math.round(performance.now() - started),
    virtualMs: (scenario.steps[Math.max(0, played - 1)]?.at ?? 0) - (scenario.steps[0]?.at ?? 0),
    stoppedEarly,
    violations: result.violations.length,
  };
}

/** Plays `name` in real time (each step at its virtual time; a wait over `maxWaitMs` is cut to it) with
 *  the pane's motion as the page has it, while a per-frame watcher (chatChurnWatch.ts) reads every drawn
 *  row: the layout shifts above the reader's anchor and the rows drawn under a second. */
async function live(name: string, { maxWaitMs = 3_000 }: { maxWaitMs?: number } = {}): Promise<ChurnReport> {
  if (name.startsWith("file:")) maxWaitMs = Math.min(maxWaitMs, 1_500);
  const scenario = await scenarioNamed(name);
  const sim = createSimulation(scenario, { rowsInTraceUpTo: 0 });
  // A clean pane first: the last scenario's rows leaving are not this one's.
  flushSync(() => show({ rows: [], working: false, sends: 0 }));
  await frame();
  await frame();
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll") ?? document.body;
  const watch = watchChurn(scroller);
  let sends = 0;
  let turn = 0;
  let last = scenario.steps[0]?.at ?? 0;
  for (let index = 0; index < scenario.steps.length; index += 1) {
    const step = scenario.steps[index]!;
    // fixed-wait: each step lands at its own virtual time, so motion between steps plays as it would live.
    await sleep(Math.min(Math.max(0, step.at - last), maxWaitMs));
    last = step.at;
    watch.mark(step.label);
    const rows = sim.advance(index);
    if (!rows) continue;
    const state = sim.state();
    if (state.turn !== turn) {
      turn = state.turn;
      sends += 1;
    }
    show({ rows, working: state.working, sends });
  }
  // fixed-wait: rows drawn in the last step must outlive the 1 s flash window to be judged.
  await sleep(2_000);
  return watch.stop();
}

Object.assign(window, { __chatSim: { run, at, dump, watch, live } });
