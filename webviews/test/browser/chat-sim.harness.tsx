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
import { runSimulationAsync, type SimResult } from "../../src/agent-session/acpmux/sim/run";
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
document.documentElement.dataset.agentMotion = "off";
document.documentElement.dataset.cmuxMotion = "off";

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
  const fixture = /^fixture:([\w.-]+)$/.exec(name);
  if (fixture) {
    const text = (await import(`../fixtures/chat-sim/${fixture[1]}.ndjson?raw`)).default as string;
    return replayScenario(fixture[1]!, parseRecords(text));
  }
  if (name === "replay") {
    const text = (await import("../fixtures/chat-sim/replay-lane-session.ndjson?raw")).default as string;
    return replayScenario("replay-lane-session", parseRecords(text));
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

/** Plays `name` and, at every step, the blank band over each one-line row (another agent's line, a
 *  "Received N messages" row, a tool run): its ink top less the ink bottom of the nearest row above
 *  that draws something. Returns the bands over `min` px, with the rows around them. */
async function scan(name: string, min = 40) {
  const scenario = await scenarioNamed(name);
  let sends = 0;
  let turn = 0;
  const found: unknown[] = [];
  const seen = new Set<string>();
  await runSimulationAsync(scenario, async (rows, step, index, state) => {
    if (state.turn !== turn) {
      turn = state.turn;
      sends += 1;
    }
    const boxes = await measure(rows, state.working, sends);
    const drawn = dump();
    let inkBottom: number | undefined;
    for (let at = 0; at < drawn.length; at += 1) {
      const row = drawn[at]!;
      if (!Number.isFinite(row.inkTop)) continue;
      const band = inkBottom === undefined ? 0 : row.inkTop - inkBottom;
      const line = /acpmux-row--line|laneNoticeBatch/.test(row.className);
      if (line && band > min && !seen.has(`${row.id}:${Math.round(band)}`)) {
        seen.add(`${row.id}:${Math.round(band)}`);
        found.push({
          step: index,
          label: step.label,
          band,
          row: row.id,
          rows: drawn.slice(Math.max(0, at - 4), at + 3),
        });
      }
      inkBottom = Math.max(inkBottom ?? -Infinity, row.inkBottom);
    }
    return boxes;
  });
  return found;
}

/** A drawn row's ink: the union of the boxes of what paints in it (text, an icon, an image), never a
 *  wrapper's padding or something drawn invisible. */
function inkOf(element: HTMLElement): { top: number; bottom: number } | undefined {
  let top = Infinity;
  let bottom = -Infinity;
  for (const child of element.querySelectorAll<HTMLElement | SVGElement>("*")) {
    const box = child.getBoundingClientRect();
    if (box.height === 0 || box.width === 0) continue;
    const paints =
      child instanceof SVGSVGElement ||
      child.tagName === "IMG" ||
      child.tagName === "CANVAS" ||
      [...child.childNodes].some((node) => node.nodeType === Node.TEXT_NODE && node.textContent!.trim());
    if (!paints) continue;
    const style = getComputedStyle(child);
    if (style.visibility === "hidden" || Number(style.opacity) === 0) continue;
    top = Math.min(top, box.top);
    bottom = Math.max(bottom, box.bottom);
  }
  return Number.isFinite(top) ? { top, bottom } : undefined;
}

export type BandFinding = {
  step: number;
  label: string;
  /** `first-frame`: read in the frame the rows changed, before the stack corrects its estimates;
   *  `settled`: two frames later. */
  frame: "first-frame" | "settled";
  /** `band`: blank space over a row, ink to ink; `empty-row`: a row with height and nothing drawn in it;
   *  `bare-actions`: a turn's action row with nothing of its turn drawn between its opening row and it. */
  kind: "band" | "empty-row" | "bare-actions";
  row: string;
  px: number;
  rows: { id: string; top: number; bottom: number; ink?: { top: number; bottom: number }; text: string }[];
};

/** The drawn rows' boxes and ink, top to bottom. */
function drawnRows() {
  return [...document.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)]
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return {
        id: element.dataset.rowId!,
        top: rect.top,
        bottom: rect.bottom,
        ink: inkOf(element),
        text: element.innerText.replace(/\s+/g, " ").slice(0, 80),
      };
    })
    .filter((row) => row.bottom - row.top > 0)
    .sort((a, b) => a.top - b.top);
}

/** The blank bands over `min` px, the empty rows and the bare action rows drawn now. */
function bandsNow(
  byId: ReadonlyMap<string, AcpmuxRow>,
  min: number,
  where: Pick<BandFinding, "step" | "label" | "frame">,
): BandFinding[] {
  const drawn = drawnRows();
  const found: BandFinding[] = [];
  const around = (at: number) => drawn.slice(Math.max(0, at - 3), at + 2);
  let inkBottom: number | undefined;
  // Rows that drew something since the turn's opening row (its prompt or incoming line).
  let since = 0;
  for (let at = 0; at < drawn.length; at += 1) {
    const row = drawn[at]!;
    const kind = byId.get(row.id)?.kind;
    if (kind === "user") since = 0;
    if (!row.ink) {
      if (row.bottom - row.top >= min / 2)
        found.push({ ...where, kind: "empty-row", row: row.id, px: row.bottom - row.top, rows: around(at) });
      continue;
    }
    if (inkBottom !== undefined && row.ink.top - inkBottom > min)
      found.push({ ...where, kind: "band", row: row.id, px: row.ink.top - inkBottom, rows: around(at) });
    if (kind === "turnSummary" && since === 0)
      found.push({ ...where, kind: "bare-actions", row: row.id, px: 0, rows: around(at) });
    if (kind !== "user") since += 1;
    inkBottom = Math.max(inkBottom ?? -Infinity, row.ink.bottom);
  }
  return found;
}

/** Plays `name` and, at every step, reads the drawn rows in the frame they changed and settled, for
 *  blank bands over `min` px, rows with height and nothing drawn, and an action row with nothing of its
 *  turn over it (Leo, 2026-11-22 22:08Z: "WHY DID IT FUCKING DISPLAY NOTHING THEN COPY BUTTONS THEN YOU
 *  SENT SHIT"). The pane is tall enough that every row draws. */
async function bands(name: string, min = 48): Promise<{ steps: number; found: BandFinding[] }> {
  const scenario = await scenarioNamed(name);
  let sends = 0;
  let turn = 0;
  const found: BandFinding[] = [];
  const seen = new Set<string>();
  const keep = (each: BandFinding[]) => {
    for (const finding of each) {
      const key = `${finding.frame}:${finding.kind}:${finding.row}:${Math.round(finding.px / 8)}`;
      if (seen.has(key)) continue;
      seen.add(key);
      found.push(finding);
    }
  };
  const result = await runSimulationAsync(scenario, async (rows, step, index, state) => {
    if (state.turn !== turn) {
      turn = state.turn;
      sends += 1;
    }
    const byId = new Map(rows.map((row) => [row.id, row]));
    flushSync(() => show({ rows, working: state.working, sends }));
    keep(bandsNow(byId, min, { step: index, label: step.label, frame: "first-frame" }));
    await frame();
    await frame();
    keep(bandsNow(byId, min, { step: index, label: step.label, frame: "settled" }));
    const boxes = new Map(drawnRows().map((row) => [row.id, { top: row.top, bottom: row.bottom }]));
    return rows.map((row) => boxes.get(row.id));
  });
  return { steps: result.steps, found };
}

Object.assign(window, { __chatSim: { run, at, dump, scan, bands } });
