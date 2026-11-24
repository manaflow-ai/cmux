// l10n-allow-file: gallery fixtures (sample queued prompts), not shipped UI.
// Leo, 2026-11-22: "unsending a message that didnt already get sent should have proper animations
// too, i think. an "un-pop"?" Three prompts wait behind a running turn; the play hits the x on the
// last one (its text goes back to the composer) and samples every frame: the rows above it, the
// composer, the restored text and the un-pop's copy (conversation/unpopMorph.ts). Each variant pins
// one arm of `composer-unpop` (unpop.experiment.ts); `instant` is today's, the control. Its play
// fails unless the un-pop is one phase (gallery/motionPhases.ts), the restored text never moves once
// drawn, the rows above never turn back, and no frame draws the row and the restored text at once.
// test/agent-pane-composer-unpop.test.ts runs every variant and records the numbers.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { countMotionPhases, type MotionSample } from "../../gallery/motionPhases";
import type { PlayContext } from "../../gallery/play";
import { armIds } from "../../experiments/experiment";
import { composerUnpop } from "./conversation/unpop.experiment";
import { COMPOSER_EDITOR } from "./composerSelectors";

/// The boxes an un-pop moves: the two rows above the taken-back one, the composer card, the restored
/// text once drawn, and the un-pop's copy of the words.
const BOXES = ["above1", "above2", "composer", "text", "copy"] as const;
const SAMPLE_MS = 900;
/// The host's answer to the removal, a little late, as the app's is.
const REMOVE_MS = 60;

const TAKEN = "Also check the retry budget:\n- cap it at five tries\n- log each backoff";

type Sample = MotionSample<(typeof BOXES)[number]> & { row: boolean; drawn: boolean };

const snapshot = chat([user("Add retries", 1), assistant("Reading the helper…", 0.5, { streaming: true })], {
  isWorking: true,
  queue: [
    { id: "q1", prompt: "Then add a test for the 429 path" },
    { id: "q2", prompt: "And update the README" },
    { id: "q3", prompt: TAKEN },
  ],
});

/// Every frame from just before the x to SAMPLE_MS after it, read after the frame's observers ran.
function sample(doc: Document): Promise<Sample[]> {
  const win = doc.defaultView!;
  const frames: Sample[] = [];
  const top = (node: Element | null | undefined) =>
    node?.isConnected ? Math.round(node.getBoundingClientRect().top * 10) / 10 : null;
  const row = (id: string) => doc.querySelector(`.acpmux-queued[data-prompt-id="${id}"]`);
  const channel = new win.MessageChannel();
  let start = -1;
  let now = 0;
  return new Promise<Sample[]>((resolve) => {
    channel.port1.onmessage = () => {
      const taken = row("q3");
      const editor = doc.querySelector<HTMLElement>(COMPOSER_EDITOR);
      const drawn =
        !!editor &&
        (editor.textContent ?? "").includes("retry budget") &&
        Number(win.getComputedStyle(editor).opacity) >= 0.99;
      frames.push({
        t: Math.round(now - start),
        above1: top(row("q1")),
        above2: top(row("q2")),
        composer: top(doc.querySelector(".acpmux-composer-box")),
        text: drawn ? top(editor) : null,
        copy: top(doc.querySelector('[data-unpop-ghost="text"]')),
        row: !!taken?.isConnected && win.getComputedStyle(taken).visibility === "visible",
        drawn,
      });
      if (now - start < SAMPLE_MS) win.requestAnimationFrame(tick);
      else resolve(frames);
    };
    // raf-read: the motion is the behavior; each frame is read as it is drawn.
    const tick = (at: number) => {
      if (start < 0) start = at;
      now = at;
      channel.port2.postMessage(0);
    };
    win.requestAnimationFrame(tick);
  });
}

export type UnpopReport = {
  phases: number;
  maxJump: number;
  /// Frames the restored text moved after its first drawn frame.
  textMoves: number;
  /// Frames the rows above moved, and whether they turned back.
  aboveMoves: number;
  aboveTurns: boolean;
  /// Frames that drew the queued row and the restored text both.
  doubles: number;
  detail: string[];
};

export function unpopReport(frames: readonly Sample[]): UnpopReport {
  const { phases, maxJump, detail } = countMotionPhases(frames, BOXES);
  let textMoves = 0;
  let aboveMoves = 0;
  const signs = new Set<number>();
  for (let index = 1; index < frames.length; index += 1) {
    const before = frames[index - 1]!;
    const at = frames[index]!;
    if (before.text != null && at.text != null && Math.abs(at.text - before.text) > 0.5) textMoves += 1;
    let moved = false;
    for (const key of ["above1", "above2"] as const) {
      const from = before[key];
      const to = at[key];
      if (from == null || to == null || Math.abs(to - from) <= 0.5) continue;
      moved = true;
      signs.add(Math.sign(to - from));
    }
    if (moved) aboveMoves += 1;
  }
  return {
    phases,
    maxJump,
    textMoves,
    aboveMoves,
    aboveTurns: signs.size > 1,
    doubles: frames.filter((frame) => frame.row && frame.drawn).length,
    detail,
  };
}

function takeBack(arm: string) {
  return async (ctx: PlayContext) => {
    const doc = ctx.document;
    await ctx.waitFor(() => doc.querySelector('.acpmux-queued[data-prompt-id="q3"]'));
    await ctx.hover({ selector: '.acpmux-queued[data-prompt-id="q3"] .acpmux-queued-text' });
    const frames = sample(doc);
    await new Promise((resolve) => setTimeout(resolve, 80));
    await ctx.click({ selector: '.acpmux-queued[data-prompt-id="q3"] [data-action="cancel-edit"]' });
    const report = unpopReport(await frames);
    doc.documentElement.dataset.unpopReport = JSON.stringify(report);
    const drawnAt = (await frames).findIndex((frame) => frame.drawn);
    if (drawnAt < 0) throw new Error("the taken-back text never showed in the composer");
    // Today's (the control) is recorded, not failed: it is the before.
    if (arm === "instant") return;
    const problems = [
      report.phases > 1 && `${report.phases} phases: ${report.detail.join("; ")}`,
      report.textMoves > 0 && `the restored text moved ${report.textMoves} times after it showed`,
      report.aboveTurns && "the rows above turned back",
      report.doubles > 0 && `${report.doubles} frames drew the row and the restored text both`,
    ].filter(Boolean);
    if (problems.length) throw new Error(`un-pop (${arm}): ${problems.join("; ")}`);
  };
}

const variants: Record<string, AgentPaneVariant> = {};
for (const arm of armIds(composerUnpop))
  variants[arm] = {
    note: `Play: the x on the last of three queued prompts puts its text back in the composer; ${composerUnpop.arms[arm].description}`,
    snapshot,
    experiments: { [composerUnpop.id]: arm },
    native: { "chat.queue.remove": { removed: true } },
    nativeDelayMs: { "chat.queue.remove": REMOVE_MS },
    play: takeBack(arm),
  };

export default agentPaneEntry({
  id: "agent-pane.composer-unpop",
  title: "Un-pop: a queued prompt taken back",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1100 },
  checks: {
    layoutShiftMax: {
      value: 1,
      reason: "The queue and the composer change height on purpose; the play counts the un-pop's phases itself.",
    },
  },
  covers: [
    "agent-session/acpmux/conversation/unpopMorph.ts",
    "agent-session/acpmux/conversation/unpop.experiment.ts",
    "agent-session/acpmux/ComposerQueue.tsx",
  ],
  keywords: ["unpop", "un-pop", "queue", "cancel edit", "take back", "unsend", "motion"],
  variants,
  experiment: {
    definition: composerUnpop,
    script: [{ name: "take the last queued prompt back", run: takeBack("compare") }],
  },
});
