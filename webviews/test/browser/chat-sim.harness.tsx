// l10n-allow-file: test fixture chats, not shipped UI.
// The chat simulator's browser lane (src/agent-session/acpmux/sim/README.md): the same run as
// `bun scripts/chat-sim.ts` (the pane's reducer, turn view and layout on virtual time), drawn at every
// step by the real VirtualTranscript with the pane's CSS, and probed by the rows' drawn boxes
// (`.acpmux-row[data-row-id]`), so rule (a) reads the gaps the reader sees and rule (b) the folds the
// stack draws. `window.__chatSim.run(name)` plays a scenario (or `replay`, the sanitized fixture) and
// returns the result without its per-step trace (`traces` keeps the steps that broke a rule).
//
// The page's motion is off (`data-agent-motion=off`), so a box is where its row rests, not a frame of a
// move. `?width=` sets the pane's width (default 720).
import { useLayoutEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
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

// fixed-wait: the churn lane replays a scenario in real time; the wall-clock gap between steps is what it measures.
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

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

// fixed-wait: exposes live(), whose waits are the real-time replay itself.
Object.assign(window, { __chatSim: { run, at, dump, live } });
