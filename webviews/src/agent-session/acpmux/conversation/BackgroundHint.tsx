// "⌃B to run in background" at the right of a running turn's live line while a command runs
// (Thinking.tsx, WorkingFor.tsx), never on the command's own transcript row (Leo, 2026-10-22: "it
// should prob go down"). Claude Code says it too; only while Ctrl-B moves something
// (runInBackground.ts), so it never offers what nothing can do. It is a button that does what Ctrl-B
// does: Ctrl-B goes to whichever pane has the keyboard, and the hint shows on hover in a pane that
// may not (Leo, 2026-11-03: "this run in background sometimes i can't actually do anything to put it
// in the background"). It fades in after a moment, so a quick command never shows it. Find skips
// it: it is a hint, not output.
import { useContext } from "react";
import { useT } from "../i18n";
import { RunInBackgroundContext } from "./runInBackground";

export function BackgroundHint() {
  const t = useT();
  const runInBackground = useContext(RunInBackgroundContext);
  if (!runInBackground) return null;
  return (
    <button
      type="button"
      className="cv-command__bg"
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
