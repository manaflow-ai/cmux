// "⌃B to run in background" on a running command's row (CommandRow, a lone shell's ToolRow), where
// Claude Code says it too; only in a chat whose work Ctrl-B moves (runInBackground.ts). It fades
// in after a moment, so a quick command never shows it. Find skips it: it is a hint, not output.
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
