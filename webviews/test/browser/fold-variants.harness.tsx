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
import {
  TURN_END_ATTR,
  TURN_END_CARD,
  TURN_END_RECAP_ATTR,
  TURN_END_SNAPSHOT_ATTR,
  TURN_END_SUBAGENT_ATTR,
} from "../../src/agent-session/acpmux/conversation/turnEndFold";
import { TURN_FOLD_GHOST } from "../../src/agent-session/acpmux/conversation/turnFold";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { fuzzScenario, strayScenario, leoFoldScenario } from "./fold-fuzz.scenario";
import { defineTranscriptMotion, TRANSCRIPT_MOTION } from "../support/transcriptMotion";
import { runSimulationAsync } from "../../src/agent-session/acpmux/sim/run";
import { parseRecords } from "../../src/agent-session/acpmux/sim/sanitize";
import { replayScenario, sim, type SimScenario, SIM_START } from "../../src/agent-session/acpmux/sim/script";
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
/** A fuzz seed's longest real gap between two steps: long enough for any fold to finish between them. */
const FUZZ_GAP_CAP_MS = Number(query.get("gapCap")) || 900;

type PaneState = {
  rows: readonly AcpmuxRow[];
  working: boolean;
  sends: number;
  look?: string;
  recap?: string;
  subagent?: string;
};
let show: (next: PaneState) => void = () => {};
const expanded = new Set<string>();
/// The sim's clock runs from SIM_START: offset to this page's, every row the chat plays happened after it
/// opened, so live rows enter (the recap card among them) as they do in a live chat.
const SIM_CLOCK_OFFSET = Date.now() - SIM_START;

function Pane() {
  const [state, setState] = useState<PaneState>({
    rows: [],
    working: false,
    sends: 0,
  });
  useLayoutEffect(() => {
    show = setState;
  }, []);
  return (
    <div
      className="acpmux-shell"
      data-turn-end-fold={state.look}
      // The control (`none`): the swap applies at once (fold.ts `jump`), so the matrix reads what the
      // turn's end does with no fold at all.
      {...(state.look === "none" && { "data-fold-look": "jump" })}
      {...{
        [TURN_END_RECAP_ATTR]: state.recap,
        [TURN_END_SUBAGENT_ATTR]: state.subagent,
      }}
    >
      {/* The look's name, for the matrix's side-by-side clips; outside the thread, so never sampled. */}
      <div
        style={{
          position: "fixed",
          right: 8,
          top: 8,
          zIndex: 10,
          font: "600 14px system-ui",
          color: "var(--agent-text)",
          opacity: 0.7,
          pointerEvents: "none",
        }}
      >
        {state.look}
      </div>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={state.rows as AcpmuxRow[]}
            sessionId="fold-variants"
            clockOffset={SIM_CLOCK_OFFSET}
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

/// The turn's closing recap: acpmux's `wrap_up` call, drawn as the next-step card under the answer once
/// the turn ends (wrapUp.ts). Leo, 2026-11-22: "that's the recap".
const RECAP = {
  recap: "The retry loop made one call too many; it now makes exactly `attempts` calls and the net suite passes.",
  ask: "Should I open a PR for this?",
  actions: ["Yes, open PR", "Not now"],
};

/// A long Claude turn: three runs of calls with notes between them, then the answer. Its end folds
/// fifteen calls and two notes under one Worked for: the big fold. `recap`: the turn closes on a
/// wrap-up call, whose card comes in under the answer as the turn ends. `subagent`: a subagent runs in
/// the middle of the work, and its block stays out of the fold (turns.ts `staysOut`).
function bigClaudeTurn({ recap = false, subagent = false } = {}): SimScenario {
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
  b.tool("bun test test/retry.test.ts -t jitter", {
    status: "failed",
    output: "1 fail",
  });
  b.tool("rg -n attempts src/net", { kind: "search" });
  b.say("The jitter case fails: the loop makes one call too many. Checking the backoff next.");
  b.tool("Read src/net/backoff.ts", { kind: "read" });
  if (subagent)
    b.subagent("Scan the last 50 CI logs for the flaky retry test", {
      ms: 1_500,
      tracked: true,
    });
  b.tool("Edit src/net/retry.ts", { kind: "edit", path: "src/net/retry.ts" });
  b.tool("bun test test/retry.test.ts");
  b.tool("bun test test/net");
  b.tool("bunx tsc --noEmit -p .");
  b.say("The count is right now; adding a case for a zero cap.");
  b.tool("Edit test/retry.test.ts", {
    kind: "edit",
    path: "test/retry.test.ts",
  });
  b.tool("bun test test/retry.test.ts -t cap");
  b.tool("bun test test/net");
  b.tool("git diff --stat");
  b.say(ANSWER);
  if (recap) b.tool("mcp__acpmux__wrap_up", { kind: "other", rawInput: RECAP });
  return b.turnEnd().build();
}

/// One cell of the fold matrix (scripts/fold-matrix.ts): a fixed base turn with one thing changed.
/// The shapes follow Leo's recorded chats (hq#17661's fixtures) with made-up text, so the clips are public.
export type MatrixCell = {
  /** Calls in the turn that folds. */
  calls: number;
  /** `between`: a line of the model's chatter after every fifth call. */
  chatter: "none" | "between";
  /** A steer from the person halfway through. */
  steer: boolean;
  /** A subagent call halfway through. */
  subagent: boolean;
  /** `up`: the reader scrolled 400 px up before the turn ended. */
  viewport: "bottom" | "up";
  /** `during`: the turn ends 20 ms after the answer's last chunk, while it still streams in; `after`: 1.5 s later. */
  timing: "during" | "after";
  /** `recap`: a long closing recap that fills the view (the end of a long coordinator turn). */
  answer: "short" | "recap";
  /** The turn closes on acpmux's wrap-up call, its recap card coming in under the answer (Leo's "the recap"). */
  wrapUp?: "short" | "long";
  /** How the turn ends (Leo, 2026-11-22: "tool calls at various times and turn ends at various"): `tool`, right
   *  after its last call with no answer; `output`, its last call printing 12 lines before the answer. */
  ending?: "answer" | "tool" | "output";
};

const COMMANDS = ["bun test test/net", "rg -n attempts src", "git status --short", "bun x tsc --noEmit -p ."];
const LONG_ANSWER = Array.from(
  { length: 6 },
  (_, index) =>
    `${index + 1}. Lane ${index + 1} finished its part: the change is pushed, its checks passed on the fleet, and ` +
    "the follow-up it found is filed with the measurement that showed it, so nothing waits on a person.",
).join("\n\n");

function matrixTurn(cell: MatrixCell): SimScenario {
  const b = sim(`matrix`, "One fold-matrix cell: a long Claude turn folding into Worked for.", "claude");
  for (let turn = 0; turn < 2; turn += 1) {
    b.prompt(`Earlier question ${turn + 1}: where does the retry helper live?`);
    b.say(`Earlier answer ${turn + 1}: in src/net/retry.ts, beside its backoff.`);
    b.turnEnd();
  }
  b.prompt("Run the lanes, fix what they find, and tell me where it all stands.");
  b.think("Starting with the failing suites.");
  const half = Math.floor(cell.calls / 2);
  for (let call = 0; call < cell.calls; call += 1) {
    if (call === half && cell.subagent)
      b.subagent("Survey the other lanes' open PRs", {
        ms: 1_500,
        report: "Three PRs open, two green.",
        tracked: true,
      });
    if (call === half && cell.steer) b.steer("also check the nightly while you're at it");
    const kind = call % 4 === 0 ? "read" : call % 4 === 1 ? "search" : undefined;
    const lastOutput = cell.ending === "output" && call === cell.calls - 1;
    b.tool(
      kind === "read" ? `Read src/lane/part-${call}.ts` : `${COMMANDS[call % COMMANDS.length]} # ${call}`,
      {
        ...(kind ? { kind } : {}),
        ms: 400,
        ...(lastOutput && {
          output: Array.from({ length: 12 }, (_, line) => `ok ${line + 1} test/lane/part-${line}.test.ts`).join("\n"),
        }),
      },
      200,
    );
    if (cell.chatter === "between" && call % 5 === 4 && call < cell.calls - 1)
      b.say(`Step ${call + 1} of ${cell.calls} done; the next part reads the lane's own tests.`, { chunks: 2 });
  }
  if (cell.viewport === "up") b.reader({ scrollBy: -400 });
  const answer = cell.answer === "recap" ? LONG_ANSWER : ANSWER;
  if (cell.ending !== "tool")
    b.say(answer, {
      chunks: cell.answer === "recap" ? 12 : 4,
      chunkMs: 90,
      after: 400,
    });
  if (cell.wrapUp)
    b.tool("mcp__acpmux__wrap_up", {
      kind: "other",
      rawInput: cell.wrapUp === "long" ? { ...RECAP, recap: LONG_ANSWER.split("\n\n").slice(0, 4).join(" ") } : RECAP,
    });
  return b.turnEnd("completed", cell.timing === "during" ? 20 : 1_500).build();
}

async function scenarioNamed(name: string): Promise<SimScenario> {
  if (name.startsWith("fuzz:")) return fuzzScenario(Number(name.slice(5))).scenario;
  if (name.startsWith("stray:")) return strayScenario(Number(name.slice(6))).scenario;
  // `sim:NAME`: a chat-sim scenario by name (sim/scenarios.ts), such as `sim:notice-no-tool-turn`.
  if (name.startsWith("sim:")) {
    const { SCENARIOS } = await import("../../src/agent-session/acpmux/sim/scenarios");
    const make = SCENARIOS[name.slice(4)];
    if (!make) throw new Error(`no chat-sim scenario ${name.slice(4)}`);
    return make();
  }
  if (name.startsWith("matrix:")) return matrixTurn(JSON.parse(decodeURIComponent(name.slice(7))) as MatrixCell);
  // `url:PATH`: a recorded chat (ndjson) the dev server serves, such as one fetched outside the repo.
  if (name.startsWith("url:")) {
    const text = await (await fetch(name.slice(4))).text();
    return replayScenario(name.slice(4), parseRecords(text));
  }
  if (name === "replay") {
    const text = (await import("../fixtures/chat-sim/replay-lane-session.ndjson?raw")).default as string;
    return replayScenario("replay-lane-session", parseRecords(text));
  }
  return bigClaudeTurn({
    recap: name.includes("recap"),
    subagent: name.includes("subagent"),
  });
}

/// A row's top, height and ink, and (when a clip hides part of it) the top and height of what it shows in the view.
type Sample = {
  t: number;
  folding: boolean;
  view: number;
  /** The transcript's whole height and scroll offset (the fold fuzzer's total-height check). */
  scrollHeight: number;
  scrollTop: number;
  rows: [key: string, top: number, height: number, ink: number, shownTop?: number, shownHeight?: number][];
  /** Every mounted row, in view or not: its key, its top from the thread's top, its height and its kind
   *  (the `acpmux-KIND` class), so a run can add up the turn's height frame by frame. */
  all: [key: string, offset: number, height: number, kind: string][];
};

/// What an `inset()` clip hides of a box's top and bottom (px; the negative insets of an open edge hide nothing).
function insetOf(clip: string): { top: number; bottom: number } | undefined {
  const match = /^inset\((-?[\d.]+)px(?:\s+(-?[\d.]+)px)?(?:\s+(-?[\d.]+)px)?/.exec(clip);
  if (!match) return undefined;
  const top = Number(match[1]);
  const bottom = Number(match[3] ?? match[1]);
  return { top: Math.max(0, top), bottom: Math.max(0, bottom) };
}

const keys = new WeakMap<Element, string>();
let ghosts = 0;
/** Each drawn row's and fold copy's top, height and ink, inside the view, this frame. */
function sampleFrame(): Sample {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  const thread = document.querySelector<HTMLElement>(".acpmux-thread");
  const view = scroller?.getBoundingClientRect();
  const rows: Sample["rows"] = [];
  const all: Sample["all"] = [];
  const threadTop = thread?.getBoundingClientRect().top ?? 0;
  for (const element of thread?.querySelectorAll<HTMLElement>(":scope > .acpmux-row") ?? []) {
    const snapshotOf = element.getAttribute(TURN_END_SNAPSHOT_ATTR);
    const opens = element.dataset.opensTurn === "true";
    let key = element.dataset.rowId ?? (snapshotOf ? `snap:${snapshotOf}` : keys.get(element));
    if (!key) {
      key = element.classList.contains(TURN_FOLD_GHOST) ? `ghost-${(ghosts += 1)}` : `row-${(ghosts += 1)}`;
      keys.set(element, key);
    }
    const box = element.getBoundingClientRect();
    const kind = /\bacpmux-(user|assistant|tool|agent|[a-z]+-?[a-z]*)\b/.exec(
      [...element.classList].filter((name) => name !== "acpmux-row" && !name.startsWith("acpmux-row--")).join(" "),
    )?.[1];
    all.push([key, box.top - threadTop, box.height, opens ? "opener" : (kind ?? "?")]);
    if (!view || box.bottom < view.top || box.top > view.bottom || box.height === 0) continue;
    // Ink is the opacity times the share its clip leaves drawn of the part of the box in the view (`wipe`
    // and its kin replace rows by clipping, not fading). The band the clip shows is read inside the view
    // too: a clip changing on the part of a row past the view's edge is nothing the reader sees.
    const style = getComputedStyle(element);
    const inset = style.clipPath === "none" ? undefined : insetOf(style.clipPath);
    const opacity = Number(style.opacity);
    if (inset) {
      const from = Math.max(box.top, view.top);
      const to = Math.min(box.bottom, view.bottom);
      const shownTop = Math.min(to, Math.max(from, box.top + inset.top));
      const shown = Math.max(0, Math.min(to, box.bottom - inset.bottom) - shownTop);
      const ink = to > from ? opacity * (shown / (to - from)) : 0;
      rows.push([key, box.top - view.top, box.height, ink, shownTop - view.top, shown]);
    } else rows.push([key, box.top - view.top, box.height, opacity]);
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
  return {
    t: performance.now(),
    folding: !!thread?.hasAttribute(TURN_END_ATTR),
    view: view?.height ?? 0,
    scrollHeight: scroller?.scrollHeight ?? 0,
    scrollTop: scroller?.scrollTop ?? 0,
    rows,
    all,
  };
}

/// A reader step as a person's wheel: a `wheel` event on the transcript each frame (what the pane reads as
/// the reader's hand, userScroll.ts) and the offset moved by a share of the step, over `WHEEL_FRAMES` frames.
const WHEEL_FRAMES = 6;
async function wheelScroll(reader: { scroll: "top" | "bottom" } | { scrollBy: number }) {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return;
  const target =
    "scrollBy" in reader ? scroller.scrollTop + reader.scrollBy : reader.scroll === "top" ? 0 : scroller.scrollHeight;
  for (let frame = 1; frame <= WHEEL_FRAMES; frame += 1) {
    const goal = "scroll" in reader && reader.scroll === "bottom" ? scroller.scrollHeight : target;
    const step = (goal - scroller.scrollTop) / (WHEEL_FRAMES - frame + 1);
    scroller.dispatchEvent(
      new WheelEvent("wheel", {
        deltaY: step,
        bubbles: true,
        cancelable: true,
      }),
    );
    scroller.scrollTop += step;
    await new Promise((resolve) => requestAnimationFrame(resolve));
  }
}

// fixed-wait: the steps' real clock is what this page records; a turn plays at the pace a live one does.
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const painted = () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));

/// Plays the chat with fold look `look`, and returns every frame's rows from its last turn's end on.
/// `end` picks another turn's end (a step index; the chat stops there), and the steps until shortly
/// before it play without waiting, so a long recorded chat reaches its big fold in seconds.
async function run(
  look: string,
  name = "big-claude-turn",
  tailMs = 1_400,
  end?: number,
  options: { recap?: string; subagent?: string } = {},
) {
  // A matrix cell plays its window on the steps' own clock (capped at 1.5 s a gap), so its timing is the chat's.
  const virtual = name.startsWith("matrix:");
  // A fuzz seed (scripts/fold-fuzz.ts) names its own fold turn end and window, and plays the window on
  // the steps' own clock (gaps capped at `FUZZ_GAP_CAP_MS`), so when each record lands is the seed's.
  // A stray seed (`stray:N`, fold-fuzz.ts `--sweep`) is the fuzz seed's chat with the reader's sweep after
  // it; its reader steps are a wheel's frames, as a person scrolls (`wheelScroll`).
  // `leo:N` is Leo's pinned case (fold-fuzz.scenario.ts `leoFoldScenario`), swept as a stray seed is.
  const leo = name.startsWith("leo:");
  const stray = leo || name.startsWith("stray:");
  const fuzz = name.startsWith("fuzz:")
    ? fuzzScenario(Number(name.slice(5)))
    : leo
      ? leoFoldScenario(Number(name.slice(4)))
      : stray
        ? strayScenario(Number(name.slice(6)))
        : undefined;
  const whole = fuzz?.scenario ?? (await scenarioNamed(name));
  const scenario = end === undefined ? whole : { ...whole, steps: whole.steps.slice(0, end + 1) };
  flushSync(() => show({ rows: [], working: false, sends: 0, look, ...options }));
  await painted();
  let lastEnd = scenario.steps.length - 1;
  while (lastEnd > 0 && !scenario.steps[lastEnd]!.label.startsWith("turn_result")) lastEnd -= 1;
  if (fuzz) lastEnd = fuzz.foldAt;
  const fastUntil = fuzz ? fuzz.windowFrom : end === undefined ? (virtual ? lastEnd - 60 : 0) : lastEnd - 40;
  // Sampled from the turn's last calls on, so a row that changes for the turn's end before the fold is seen.
  const sampleFrom = fuzz ? fuzz.windowFrom : Math.max(0, lastEnd - 16);
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
        window.__transcriptMotion!.start();
        requestAnimationFrame(tick);
      }
      flushSync(() => show({ rows, working: state.working, sends, look, ...options }));
      if (sampling) window.__transcriptMotion!.rows?.(rows.map((row) => [row.id, JSON.stringify(row)] as const));
      // This harness draws no "Worked for" to open: a reader's `open` step scrolls nothing here.
      const reader = step.type === "reader" && !("open" in step.reader) ? step.reader : undefined;
      if (reader && stray) {
        if (sampling) window.__transcriptMotion!.mark(`input:${step.label}`);
        await wheelScroll(reader);
      } else if (reader) {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (scroller)
          scroller.scrollTop =
            "scrollBy" in reader
              ? scroller.scrollTop + reader.scrollBy
              : "scroll" in reader
                ? reader.scroll === "top"
                  ? 0
                  : scroller.scrollHeight
                : scroller.scrollTop;
      }
      if (sampling) {
        marks.push({ step: index, t: performance.now(), label: step.label });
        // The reader's scroll is input: the detector takes it out of the rows' moves.
        if (!(stray && step.type === "reader"))
          window.__transcriptMotion!.mark(step.type === "reader" ? `input:${step.label}` : step.label);
      }
      if (index < fastUntil) {
        // fixed-wait: a yield to the event loop while fast-forwarding, so the page stays responsive.
        if (index % 50 === 0) await sleep(0);
        // fixed-wait: the gap between two steps of the chat is the timing being recorded.
      } else if (fuzz) {
        const next = scenario.steps[index + 1];
        // fixed-wait: the seed's own gap to its next record is the timing being fuzzed.
        if (next) await sleep(Math.min(FUZZ_GAP_CAP_MS, Math.max(0, next.at - step.at)));
      } else await sleep(index >= sampleFrom ? STEP_MS * 2 : STEP_MS);
      return rows.map(() => undefined);
    },
    { rowsInTraceUpTo: 0 },
  );
  // fixed-wait: the frames after the turn's end are the fold being recorded, for a set time.
  await sleep(tailMs);
  sampling = false;
  const motion = window.__transcriptMotion!.stop();
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  const view = scroller?.clientHeight ?? 0;
  // The scroll-anchoring arm in force: the browser's own (`overflow-anchor`) or the transcript's alone.
  const overflowAnchor = scroller ? getComputedStyle(scroller).overflowAnchor : "";
  const result = {
    look,
    samples,
    marks,
    startedAt: performance.timeOrigin,
    view,
    overflowAnchor,
    foldAt: lastEnd,
    motion,
  };
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
defineTranscriptMotion(TRANSCRIPT_MOTION);
/// Resizes the pane in place (the fold fuzzer reuses one page across seeds and split sizes).
function size(width: number, height: number) {
  Object.assign(root.style, { width: `${width}px`, height: `${height}px` });
}
Object.assign(window, { __fold: { run, sampleFrame, size } });
