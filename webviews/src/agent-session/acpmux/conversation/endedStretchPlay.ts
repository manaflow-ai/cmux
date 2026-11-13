// Gallery plays for a chat that still works and holds a stretch that already ended with its summary.
// Under the live-turn-work `line` a running stretch draws none of its finished runs, only
// the live line (turns.ts `codexRuns`, liveTurnWork.experiment.ts), so a variant that shows finished
// work puts it in an ended stretch, which folds under its "Worked for" line as an ended turn does.
import type { PlayContext } from "../../../gallery/play";

const WORKED = "button.cv-worked.is-toggle";

/// Opens the last ended stretch's "Worked for" line, so its runs, thoughts and calls are drawn.
export async function openEndedStretch(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(WORKED), { capMs: 10_000 });
  const line = () => [...ctx.document.querySelectorAll<HTMLElement>(WORKED)].at(-1)!;
  if (line().getAttribute("aria-expanded") !== "true") {
    line().click();
    await ctx.waitFor(() => line().getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
}
