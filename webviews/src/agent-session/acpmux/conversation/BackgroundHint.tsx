// "⌃B to run in background" at the right of a running turn's live line while a command runs
// (Thinking.tsx, WorkingFor.tsx), never on the command's own transcript row (Leo, 2026-10-22: "it
// should prob go down"). Claude Code says it too; only in a chat whose work Ctrl-B moves
// (runInBackground.ts). It fades in after a moment, so a quick command never shows it. Find skips
// it: it is a hint, not output.
import { useContext } from "react";
import { useT } from "../i18n";
import { RunInBackgroundContext } from "./runInBackground";

export function BackgroundHint() {
  const t = useT();
  if (!useContext(RunInBackgroundContext)) return null;
  return (
    <span className="cv-command__bg" data-find-skip>
      {t("tools.backgroundHint")}
    </span>
  );
}
