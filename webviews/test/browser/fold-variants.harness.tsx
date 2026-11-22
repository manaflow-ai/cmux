// l10n-allow-file: test fixture chats, not shipped UI.
// The big Claude turn fold, played at real speed in Chrome with motion on, for the fold's variants
// (turnEndFoldLook.ts). Leo, 2026-11-22: "the big fold we do for claude is not good looking enough. it
// looks like a gash collapsing. you need to figure out more and more variations to deal with things."
//
// The chat is a chat-sim scenario (sim/README.md), or the sanitized replay fixture, folded by the pane's
// real reducer and turn view and drawn by the real VirtualTranscript with the pane's CSS. Steps play on
// a short real clock (`STEP_MS`), so the turn's end, and its fold, run as they would live. Every frame
// from the turn's last step on, each drawn row's and fold copy's top and ink are read
// (`window.__fold.run(look)` returns them); scripts/fold-variants-record.ts turns them into numbers and
// a clip. `?width=` and `?height=` size the pane (default 720 x 640).
import { useLayoutEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { TURN_END_ATTR, TURN_END_CARD } from "../../src/agent-session/acpmux/conversation/turnEndFold";
import { TURN_FOLD_GHOST } from "../../src/agent-session/acpmux/conversation/turnFold";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { runSimulationAsync } from "../../src/agent-session/acpmux/sim/run";
import { parseRecords } from "../../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, sim, type SimScenario } from "../../src/agent-session/acpmux/sim/script";
import strings from "../../src/agent-session/acpmux/generated/strings.json";
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

globalThis.__cmuxPaneStrings = { en: strings.en };
const query = new URLSearchParams(location.search);
/** The real gap between two steps, capped: the turn plays in a few seconds, its end at its own pace. */
const STEP_MS = Number(query.get("step")) || 70;

type PaneState = { rows: readonly AcpmuxRow[]; working: boolean; sends: number; look?: string };
let show: (next: PaneState) => void = () => {};
const expanded = new Set<string>();

function Pane() {
  const [state, setState] = useState<PaneState>({ rows: [], working: false, sends: 0 });
  useLayoutEffect(() => {
    show = setState;
  }, []);
  return (
    <div className="acpmux-shell" data-turn-end-fold={state.look}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={state.rows as AcpmuxRow[]}
            sessionId="fold-variants"
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

const ANSWER =
  "Fixed. The retry loop counted its first call as a retry, so with `attempts: 3` it made four calls and the " +
  "fourth one ran past the backoff cap. The loop now makes exactly `attempts` calls, the jitter stays inside the " +
  "cap, and the whole net suite passes (212 tests). I also added a case for a zero cap.";

/// A long Claude turn: three runs of calls with notes between them, then the answer. Its end folds
/// fifteen calls and two notes under one Worked for: the big fold.
function bigClaudeTurn(): SimScenario {
  const b = sim("big-claude-turn", "A long Claude turn whose end folds fifteen calls and two notes.", "claude");
  for (let turn = 0; turn < 3; turn += 1) {
    b.prompt(`Earlier question ${turn + 1}: how does the retry helper back off?`);
    b.tool(`Read src/net/retry-${turn}.ts`, { kind: "read" });
    b.say(`Earlier answer ${turn + 1}: it doubles the wait each time and adds a random jitter.`);
    b.turnEnd();
  }
  b.prompt("The retry test is flaky. Find out why and fix it.");
  b.think("Reading the helper and its tests first.");
  b.tool("Read src/net/retry.ts", { kind: "read" });
  b.tool("Read test/retry.test.ts", { kind: "read" });
  b.tool("bun test test/retry.test.ts", { status: "failed", output: "1 fail" });
  b.tool("bun test test/retry.test.ts -t jitter", { status: "failed", output: "1 fail" });
  b.tool("rg -n attempts src/net", { kind: "search" });
  b.say("The jitter case fails: the loop makes one call too many. Checking the backoff next.");
  b.tool("Read src/net/backoff.ts", { kind: "read" });
  b.tool("Edit src/net/retry.ts", { kind: "edit", path: "src/net/retry.ts" });
  b.tool("bun test test/retry.test.ts");
  b.tool("bun test test/net");
  b.tool("bunx tsc --noEmit -p .");
  b.say("The count is right now; adding a case for a zero cap.");
  b.tool("Edit test/retry.test.ts", { kind: "edit", path: "test/retry.test.ts" });
  b.tool("bun test test/retry.test.ts -t cap");
  b.tool("bun test test/net");
  b.tool("git diff --stat");
  b.say(ANSWER);
  return b.turnEnd().build();
}

async function scenarioNamed(name: string): Promise<SimScenario> {
  // `url:PATH`: a recorded chat (ndjson) the dev server serves, such as one fetched outside the repo.
  if (name.startsWith("url:")) {
    const text = await (await fetch(name.slice(4))).text();
    return replayScenario(name.slice(4), parseRecords(text));
  }
  if (name === "replay") {
    const text = (await import("../fixtures/chat-sim/replay-lane-session.ndjson?raw")).default as string;
    return replayScenario("replay-lane-session", parseRecords(text));
  }
  return bigClaudeTurn();
}

type Sample = { t: number; folding: boolean; rows: [key: string, top: number, height: number, ink: number][] };

const keys = new WeakMap<Element, string>();
let ghosts = 0;
/** Each drawn row's and fold copy's top, height and ink, inside the view, this frame. */
function sampleFrame(): Sample {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  const thread = document.querySelector<HTMLElement>(".acpmux-thread");
  const view = scroller?.getBoundingClientRect();
  const rows: Sample["rows"] = [];
  for (const element of thread?.querySelectorAll<HTMLElement>(":scope > .acpmux-row") ?? []) {
    let key = element.dataset.rowId ?? keys.get(element);
    if (!key) {
      key = element.classList.contains(TURN_FOLD_GHOST) ? `ghost-${(ghosts += 1)}` : `row-${(ghosts += 1)}`;
      keys.set(element, key);
    }
    const box = element.getBoundingClientRect();
    if (!view || box.bottom < view.top || box.top > view.bottom || box.height === 0) continue;
    rows.push([key, box.top - view.top, box.height, Number(getComputedStyle(element).opacity)]);
  }
  // `morph`'s card, as the band its clip shows.
  for (const element of thread?.querySelectorAll<HTMLElement>(`:scope > .${TURN_END_CARD}`) ?? []) {
    const box = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    const inset = /inset\(([\d.]+)px\s+\S+\s+([\d.]+)px/.exec(style.clipPath);
    const top = box.top + Number(inset?.[1] ?? 0);
    const bottom = box.bottom - Number(inset?.[2] ?? 0);
    const ink = Number(style.opacity) * Number(getComputedStyle(element.firstElementChild!).opacity);
    if (view) rows.push(["fold-card", top - view.top, Math.max(0, bottom - top), ink]);
  }
  return { t: performance.now(), folding: !!thread?.hasAttribute(TURN_END_ATTR), rows };
}

// fixed-wait: the steps' real clock is what this page records; a turn plays at the pace a live one does.
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const painted = () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));

/// Plays the chat with fold look `look`, and returns every frame's rows from its last turn's end on.
/// `end` picks another turn's end (a step index; the chat stops there), and the steps until shortly
/// before it play without waiting, so a long recorded chat reaches its big fold in seconds.
async function run(look: string, name = "big-claude-turn", tailMs = 1_400, end?: number) {
  const whole = await scenarioNamed(name);
  const scenario = end === undefined ? whole : { ...whole, steps: whole.steps.slice(0, end + 1) };
  flushSync(() => show({ rows: [], working: false, sends: 0, look }));
  await painted();
  let lastEnd = scenario.steps.length - 1;
  while (lastEnd > 0 && !scenario.steps[lastEnd]!.label.startsWith("turn_result")) lastEnd -= 1;
  const fastUntil = end === undefined ? 0 : lastEnd - 40;
  const sampleFrom = Math.max(0, lastEnd - 4);
  const samples: Sample[] = [];
  let sampling = false;
  let marks: { step: number; t: number; label: string }[] = [];
  const tick = () => {
    if (!sampling) return;
    samples.push(sampleFrame());
    requestAnimationFrame(tick);
  };
  let sends = 0;
  let turn = 0;
  await runSimulationAsync(
    scenario,
    async (rows, step, index, state) => {
      if (state.turn !== turn) {
        turn = state.turn;
        sends += 1;
      }
      if (index === sampleFrom && !sampling) {
        sampling = true;
        requestAnimationFrame(tick);
      }
      flushSync(() => show({ rows, working: state.working, sends, look }));
      if (sampling) marks.push({ step: index, t: performance.now(), label: step.label });
      if (index < fastUntil) {
        // fixed-wait: a yield to the event loop while fast-forwarding, so the page stays responsive.
        if (index % 50 === 0) await sleep(0);
        // fixed-wait: the gap between two steps of the chat is the timing being recorded.
      } else await sleep(index >= sampleFrom ? STEP_MS * 2 : STEP_MS);
      return rows.map(() => undefined);
    },
    { rowsInTraceUpTo: 0 },
  );
  // fixed-wait: the frames after the turn's end are the fold being recorded, for a set time.
  await sleep(tailMs);
  sampling = false;
  const result = { look, samples, marks, startedAt: performance.timeOrigin };
  marks = [];
  return result;
}

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, {
  height: `${Number(query.get("height")) || 640}px`,
  width: `${Number(query.get("width")) || 720}px`,
  display: "flex",
  flexDirection: "column",
});
createRoot(root).render(<Pane />);
Object.assign(window, { __fold: { run, sampleFrame } });
