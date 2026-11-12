// Gallery plays for a chat that still works and holds a stretch that already ended with its summary.
// Under the shipped live-turn-work `line` a running stretch draws none of its finished runs, only
// the live line (turns.ts `codexRuns`, liveTurnWork.experiment.ts), so a variant that shows finished
// work puts it in an ended stretch, which folds under its "Worked for" line as an ended turn does.
import type { PlayContext } from "../../../gallery/play";

const WORKED = "button.cv-worked.is-toggle";
/// A "Worked for" line of a finished turn's tail (turns.ts `foldTail`): each opens on its own.
const TAIL_WORKED = `.acpmux-row[data-row-id*="~tail-"] ${WORKED}`;

/// Opens the last ended stretch's "Worked for" line, so its runs, thoughts and calls are drawn.
export async function openEndedStretch(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(WORKED), { capMs: 10_000 });
  const line = () => [...ctx.document.querySelectorAll<HTMLElement>(WORKED)].at(-1)!;
  if (line().getAttribute("aria-expanded") !== "true") {
    line().click();
    await ctx.waitFor(() => line().getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
}

/// Opens every "Worked for" line in a finished turn's tail (turns.ts `foldTail`: the work the agent did
/// on its own after the turn, a background turn's line or a task's end among it, folds in place), so
/// the rows inside are drawn. Each opens on its own, one after another, in order.
export async function openTailFolds(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(TAIL_WORKED), { capMs: 10_000 });
  const closed = () =>
    [...ctx.document.querySelectorAll<HTMLElement>(TAIL_WORKED)].find(
      (line) => line.getAttribute("aria-expanded") !== "true",
    );
  for (let line = closed(), guard = 0; line && guard < 20; line = closed(), guard += 1) {
    const id = line.closest<HTMLElement>("[data-row-id]")!.dataset.rowId!;
    const open = () =>
      ctx.document
        .querySelector(`.acpmux-row[data-row-id="${id}"] ${WORKED}`)
        ?.getAttribute("aria-expanded") === "true";
    line.click();
    await ctx.waitFor(open, { capMs: 10_000 });
  }
}
