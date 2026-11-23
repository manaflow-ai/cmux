// l10n-allow-file: test harness, not shipped UI.
// Plays one case of the layout-shift case space (src/agent-session/acpmux/sim/layoutCases.ts) in the chat
// simulator's page (chat-sim.harness.tsx): the case's chat folded step by step by the pane's real reducer
// and turn view, drawn by the real VirtualTranscript with motion ON, and the case's perturbation applied
// halfway through the streaming turn. Every step and every perturbation is tracked frame by frame with the
// gallery's box tracker (src/gallery/shift.ts `startBoxTracker`, judged by followJudge.ts: a row that moved
// other than by the shared follow or by a row next to it growing is a stray move). On top of it, three
// checks the follow judge cannot make alone:
//   - parked: while the reader is scrolled up into the chat, no row on screen may move at all (the
//     follow is a shift there);
//   - return: after a tab switch, a hidden pane, a reconnect replay or a re-delivery of the same rows,
//     every row on screen before is back where it was;
//   - provoked acts (resize, zoom, a font change) may move each box once, to its new place
//     (`firstMoveFree`); a second move is a bounce and flags.
// Leo, 2026-11-22: "EVERY POSSIBLE CASE, NO MATTER HOW WILD".
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import type { createSimulation } from "../../src/agent-session/acpmux/sim/run";
import {
  FLAG_PX,
  PERTURBATIONS,
  layoutCaseById,
  layoutCaseScenario,
  type LayoutCaseResult,
  type LayoutFlag,
} from "../../src/agent-session/acpmux/sim/layoutCases";
import { TRANSCRIPT_ROW } from "../../src/agent-session/acpmux/transcriptSelectors";
import { FOLLOW_REVERSED } from "../../src/gallery/followJudge";
import { startBoxTracker } from "../../src/gallery/shift";

type PaneState = { rows: readonly AcpmuxRow[]; working: boolean; sends: number; sessionId?: string };
export type CaseHost = {
  root: HTMLElement;
  show: (next: PaneState) => void;
  simulate: typeof createSimulation;
};

/** Steps of a long chat drawn before the case's turn (the rest is folded without drawing). */
const DRAWN_TAIL = 40;
/** A step is judged until its rows hold still this many frames, at least `MIN_FRAMES`, at most `MAX_FRAMES`. */
const QUIET_FRAMES = 6;
const MIN_FRAMES = 10;
const MAX_FRAMES = 90;

const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
const frames = async (count: number) => {
  for (let index = 0; index < count; index++) await frame();
};

type Rects = Map<string, { top: number; left: number; height: number }>;
/** Every drawn row in view, by id. */
function rowsInView(root: HTMLElement): Rects {
  const scroller = root.querySelector<HTMLElement>(".acpmux-scroll");
  const port = scroller?.getBoundingClientRect();
  const rects: Rects = new Map();
  for (const element of root.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
    const rect = element.getBoundingClientRect();
    if (rect.height <= 0) continue;
    if (port && (rect.bottom <= port.top || rect.top >= port.bottom)) continue;
    rects.set(element.dataset.rowId!, { top: rect.top, left: rect.left, height: rect.height });
  }
  return rects;
}

const signature = (rects: Rects) =>
  [...rects].map(([id, r]) => `${id}:${r.top.toFixed(1)}:${r.left.toFixed(1)}:${r.height.toFixed(1)}`).join("|");

/** Waits until the rows hold still (or `MAX_FRAMES`), returns the frames waited. */
async function settle(root: HTMLElement): Promise<number> {
  let quiet = 0;
  let last = "";
  let count = 0;
  while (count < MAX_FRAMES) {
    await frame();
    count++;
    const now = signature(rowsInView(root));
    quiet = now === last ? quiet + 1 : 0;
    last = now;
    if (count >= MIN_FRAMES && quiet >= QUIET_FRAMES) break;
  }
  return count;
}

/** Rows on screen in both `before` and `after` that moved more than `FLAG_PX`. */
function drift(before: Rects, after: Rects, step: number, kind: string): LayoutFlag[] {
  const flags: LayoutFlag[] = [];
  for (const [id, was] of before) {
    const now = after.get(id);
    if (!now) continue;
    const px = Math.max(Math.abs(now.top - was.top), Math.abs(now.left - was.left));
    if (px > FLAG_PX) flags.push({ step, label: `row ${id}`, kind, px: Math.round(px * 10) / 10 });
  }
  return flags;
}

const clone = (rows: readonly AcpmuxRow[]): AcpmuxRow[] => {
  try {
    return structuredClone(rows) as AcpmuxRow[];
  } catch {
    return rows.map((row) => ({ ...row }));
  }
};

export async function runLayoutCase(id: string, host: CaseHost): Promise<LayoutCaseResult> {
  const { root, show } = host;
  const spec = layoutCaseById(id);
  const doc = document.documentElement;
  const flags: LayoutFlag[] = [];
  let judgedFrames = 0;
  const scroller = () => root.querySelector<HTMLElement>(".acpmux-scroll");

  // A clean page: motion on, light, default font, no zoom, the case's width, an empty pane.
  doc.dataset.agentMotion = "on";
  doc.dataset.cmuxMotion = "on";
  delete doc.dataset.theme;
  doc.style.removeProperty("zoom");
  doc.style.removeProperty("--font-ui");
  doc.style.removeProperty("--text-content");
  root.style.display = "flex";
  root.style.width = `${spec.width}px`;
  show({ rows: [], working: false, sends: 0, sessionId: `case-${id}` });
  await frames(3);

  const scenario = layoutCaseScenario(spec.content);
  const sim = host.simulate(scenario);
  const firstDrawn = Math.max(0, scenario.steps.length - DRAWN_TAIL);
  const perturbAt = firstDrawn + Math.floor((scenario.steps.length - firstDrawn) / 2);
  let rows: readonly AcpmuxRow[] = [];
  let working = false;
  let sends = 0;
  let turn = 0;
  let parked = false;
  let perturbed = false;
  const sessionId = `case-${id}`;
  const draw = (next: readonly AcpmuxRow[], session = sessionId) =>
    show({ rows: next, working, sends, sessionId: session });

  /** Runs `act`, then tracks frames until the rows rest; flags its stray moves over `FLAG_PX`. */
  const judged = async (step: number, kind: string, act: () => void | Promise<void>, firstMoveFree = false) => {
    const parkedBefore = parked ? rowsInView(root) : undefined;
    const tracker = startBoxTracker(document, { restedAtStart: true, firstMoveFree });
    await act();
    judgedFrames += await settle(root);
    const shift = tracker.stop();
    for (const stray of shift.follow?.stray ?? []) {
      const px =
        stray.label === FOLLOW_REVERSED
          ? Math.abs(stray.dy)
          : Math.max(Math.abs(stray.dx), Math.abs(stray.dy - stray.follow));
      if (px > FLAG_PX) flags.push({ step, label: stray.label, kind, px: Math.round(px * 10) / 10 });
    }
    if (parkedBefore) flags.push(...drift(parkedBefore, rowsInView(root), step, `${kind}:parked`));
  };

  /** Hides what the reader sees (`away`), comes back (`back`) and flags rows not back in place. */
  const roundTrip = async (step: number, kind: string, away: () => void, back: () => void) => {
    const before = rowsInView(root);
    away();
    await frames(4);
    back();
    await frames(2);
    judgedFrames += await settle(root);
    flags.push(...drift(before, rowsInView(root), step, `${kind}:return`));
  };

  const perturb = async (step: number) => {
    const kind = spec.perturbation;
    const provoked = PERTURBATIONS[kind].provoked;
    switch (kind) {
      case "none":
        return;
      case "resize":
        return judged(step, kind, () => void (root.style.width = `${spec.width + 280}px`), provoked);
      case "split-narrow":
        return judged(step, kind, () => void (root.style.width = "340px"), provoked);
      case "zoom":
        return judged(step, kind, () => doc.style.setProperty("zoom", "1.25"), provoked);
      case "font-swap":
        return judged(
          step,
          kind,
          () => {
            doc.style.setProperty("--font-ui", "Georgia, 'Times New Roman', serif");
            doc.style.setProperty("--text-content", "15px");
          },
          provoked,
        );
      case "theme-swap":
        return judged(step, kind, () => void (doc.dataset.theme = "dark"));
      case "scroll-up-parked":
        await judged(step, kind, () => {
          const el = scroller();
          if (el) el.scrollTop = Math.max(0, el.scrollTop - 420);
        });
        parked = (scroller()?.scrollTop ?? 0) + (scroller()?.clientHeight ?? 0) < (scroller()?.scrollHeight ?? 0) - 40;
        return;
      case "tab-switch":
        return roundTrip(
          step,
          kind,
          () => draw(clone(rows).slice(0, 2), `${sessionId}-other`),
          () => draw(rows),
        );
      case "workspace-switch":
        return roundTrip(
          step,
          kind,
          () => void (root.style.display = "none"),
          () => void (root.style.display = "flex"),
        );
      case "reconnect-replay":
        return roundTrip(
          step,
          kind,
          () => draw([]),
          () => draw(clone(rows)),
        );
      case "duplicate-redelivery":
        await judged(step, kind, () => draw(clone(rows)));
        return;
      case "planted-jump":
        return judged(step, kind, () => {
          const port = scroller()?.getBoundingClientRect();
          const row = [...root.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)].findLast((element) => {
            const rect = element.getBoundingClientRect();
            return rect.height > 0 && (!port || (rect.top >= port.top && rect.bottom <= port.bottom));
          });
          if (row) row.style.marginLeft = "24px";
        });
      case "scroll-burst":
        await judged(step, kind, async () => {
          const el = scroller();
          if (!el) return;
          for (let flick = 0; flick < 8; flick++) {
            el.scrollTop += flick % 2 ? 360 : -300;
            await frame();
          }
          el.scrollTop = el.scrollHeight;
        });
        return;
      case "resize-burst": {
        for (const width of [520, 900, 400, 1100, 600, 980, 450, 820]) {
          root.style.width = `${width}px`;
          await frame();
        }
        return judged(step, kind, () => void (root.style.width = `${spec.width}px`), true);
      }
    }
  };

  let error: string | undefined;
  try {
    for (let index = 0; index < scenario.steps.length; index++) {
      const next = sim.advance(index);
      sim.check(index, undefined);
      const state = sim.state();
      working = state.working;
      if (state.turn !== turn) {
        turn = state.turn;
        sends += 1;
      }
      if (!next) continue;
      rows = next;
      if (index < firstDrawn) continue;
      if (index === firstDrawn && firstDrawn > 0) {
        // The history lands at once (a chat opened), then the case's turn plays step by step.
        draw(rows);
        await settle(root);
        const el = scroller();
        if (el) el.scrollTop = el.scrollHeight;
        await settle(root);
        continue;
      }
      if (!perturbed && index >= perturbAt) {
        perturbed = true;
        await perturb(index);
      }
      await judged(index, "step", () => draw(rows));
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    doc.dataset.agentMotion = "off";
    doc.dataset.cmuxMotion = "off";
    delete doc.dataset.theme;
    doc.style.removeProperty("zoom");
    doc.style.removeProperty("--font-ui");
    doc.style.removeProperty("--text-content");
    root.style.display = "flex";
    root.style.width = `${720}px`;
  }
  return {
    id,
    steps: scenario.steps.length - firstDrawn,
    frames: judgedFrames,
    flags,
    worst: flags.reduce((worst, flag) => Math.max(worst, flag.px), 0),
    ...(error ? { error } : {}),
  };
}
