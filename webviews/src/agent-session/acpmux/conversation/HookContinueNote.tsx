// Where a Stop hook blocked the agent's stop and the turn went on with the hook's reason (acpmux
// `hook_feedback`, conversation/hookContinueKind.ts). Claude Code sends the reason as a new input
// and no record of its own, so without this note the text after it reads as a second answer (Leo,
// 2026-11-22: "you also basically said the same thing, so there didnt seem to be a point to that.
// if you did get hooked, i think it should get displayed better"). Its look is the
// `hook-continue-look` experiment: a status line with the reason (the default), a divider or a chip;
// the whole reason, with the hook's command when Claude Code named it, is each one's tooltip.
import { useT } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import type { HookContinue } from "./hookContinueKind";
import { hookContinueLook } from "./hookContinueLook.experiment";
import { Retry } from "./icons";

export function HookContinueNote({ note }: { note: HookContinue }) {
  const t = useT();
  const look = experimentArm(hookContinueLook);
  const tip = note.hookName ? `${note.hookName}: ${note.reason}` : note.reason;
  if (look === "divider")
    return (
      <div className="cv-hook-divider" title={tip || undefined}>
        <span className="cv-hook-divider__label">{t("hookContinue.title")}</span>
      </div>
    );
  if (look === "chip")
    return (
      <div className="cv-hook-chip-row">
        <span className="cv-hook-chip" title={tip || undefined}>
          <Retry />
          {t("hookContinue.chip")}
        </span>
      </div>
    );
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-hook-continue" title={tip || undefined}>
        <span className="cv-tool__icon">
          <Retry />
        </span>
        <span className="cv-tool__text">{t("hookContinue.title")}</span>
        {note.reason ? <span className="cv-hook-continue__reason">{note.reason}</span> : null}
      </div>
    </div>
  );
}
