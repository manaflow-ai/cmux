// The chat layout-shift budget's flows, budgets and verdict, kept out of
// chat-flow-shift-budget-browser.test.ts so that file is one requireBrowserLane call (check:browser-lanes).
import { MAIN_DOCK } from "../../src/agent-session/acpmux/composerSelectors";

/// The composer's box, judged by where it paints.
export const COMPOSER = `${MAIN_DOCK} .acpmux-composer-box`;

export type FlowName = "send" | "thinking" | "compaction" | "compaction-steer" | "background" | "reload";
export const FLOWS: FlowName[] = ["send", "thinking", "compaction", "compaction-steer", "background", "reload"];
/// Per flow: the worst stray move (px), the composer's move over a step (px) and Chromium's
/// layout-shift score. A budget only comes down: a fix that lowers a flow's number lowers its row.
export const BUDGET: Record<FlowName, { stray: number; composer: number; cls: number }> = {
  send: { stray: 1, composer: 1, cls: 0.01 },
  thinking: { stray: 1, composer: 1, cls: 0.01 },
  compaction: { stray: 1, composer: 1, cls: 0.01 },
  "compaction-steer": { stray: 1, composer: 1, cls: 0.01 },
  background: { stray: 1, composer: 1, cls: 0.01 },
  reload: { stray: 1, composer: 1, cls: 0.01 },
};
/// Where base already shifts, the measured worst stands until a fix lowers it (a ratchet, per engine).
/// WebKit, send, reply: the live "Thinking" row strays when the first reply chunk replaces it, on some
/// runs and not others (8.8 px once in 14 runs on base, 0 px in 10 runs of the flow alone); the open
/// fixes for the answer shifting the thinking row lower this back to 1.
/// Compaction-steer, the states Leo named ("a message sent/steered during compaction ... the next worked
/// for + thinking"), measured in CI at 7c2f6e41 on 2026-11-25: WebKit's live "Thinking" row moves 34.8 px
/// when the steer lands during the compaction, and Chromium's follow reverses 5.5 px on the next thinking.
/// On a chat that already holds compactions (the file's order: compaction runs first), the steered turn's
/// end folds its "Working for" and the rows above move 12 px against the follow, in both engines, every run
/// (CI and local, 2026-11-26); the fix for that fold lowers Chromium's row back to 8.
export const KNOWN: Partial<Record<string, Partial<(typeof BUDGET)[FlowName]>>> = {
  "webkit send": { stray: 12 },
  "webkit compaction-steer": { stray: 40 },
  "chromium compaction-steer": { stray: 12 },
};
/// The planted jump, px.
export const SEED_PX = 24;

export type StepReport = {
  step: string;
  /** The worst stray move in the step (px), and the first few, labelled. */
  stray: number;
  strays: {
    label: string;
    dy: number;
    dx: number;
    follow: number;
    frame: number;
  }[];
  /** How far the composer's bottom moved from the step's start to its end (px). */
  composer: number;
  /** Chromium's layout-shift entries over the step (no recent input), summed; null in WebKit. */
  cls: number | null;
};

/** Every way `report` breaks `budget`, one line each (empty: inside the budget). */
export function overBudget(report: StepReport[], budget: (typeof BUDGET)[FlowName]): string[] {
  const out: string[] = [];
  for (const entry of report) {
    if (entry.stray > budget.stray)
      out.push(`${entry.step}: stray ${entry.stray}px > ${budget.stray}px (${entry.strays[0]?.label ?? "?"})`);
    if (entry.composer > budget.composer)
      out.push(`${entry.step}: composer moved ${entry.composer}px > ${budget.composer}px`);
    if (entry.cls !== null && entry.cls > budget.cls)
      out.push(`${entry.step}: layout-shift score ${entry.cls} > ${budget.cls}`);
  }
  return out;
}
