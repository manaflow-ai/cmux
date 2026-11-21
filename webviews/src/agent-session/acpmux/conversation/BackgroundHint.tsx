// "⌃B to run in background" at the right of a running turn's live line while a command runs
// (Thinking.tsx, WorkingFor.tsx), never on the command's own transcript row (Leo, 2026-10-22: "it
// should prob go down"). Claude Code says it too; only while Ctrl-B moves something
// (runInBackground.ts), so it never offers what nothing can do. It is a button that does what Ctrl-B
// does: Ctrl-B goes to whichever pane has the keyboard, and the hint shows on hover in a pane that
// may not (Leo, 2026-11-03: "this run in background sometimes i can't actually do anything to put it
// in the background"). It fades in after a moment, so a quick command never shows it. Its room is
// kept while it is offered, so pointing at the line changes its opacity and nothing else: taking
// its room on hover squeezed the line's times and tokens over each other (Leo, 2026-11-06: "this
// flickers"; backgroundHintRoom.experiment.ts). Find skips it: it is a hint, not output.
import { useContext } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT } from "../i18n";
import { backgroundHintRoom } from "./backgroundHintRoom.experiment";
import { RunInBackgroundContext } from "./runInBackground";

export function BackgroundHint() {
  const t = useT();
  const runInBackground = useContext(RunInBackgroundContext);
  if (!runInBackground) return null;
  return (
    <button
      type="button"
      className="cv-command__bg"
      data-room={experimentArm(backgroundHintRoom)}
      aria-label={t("tools.backgroundHintLabel")}
      data-find-skip
      onClick={(event) => {
        event.stopPropagation();
        runInBackground();
      }}
    >
      {t("tools.backgroundHint")}
    </button>
  );
}
