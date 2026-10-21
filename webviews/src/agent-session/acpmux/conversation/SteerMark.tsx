import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";

/// Under a prompt sent into a running turn (a steer): whether the agent has read it yet. A steer
/// waits until the step the agent is on ends (Claude Code reads it then; the rest of that reply
/// still streams above it), then reads as steered. A prompt sent now to an agent that cannot steer
/// stopped the turn and ran next.
export function SteerMark({ steer }: { steer: NonNullable<AcpmuxRow["steer"]> }) {
  const t = useT();
  return (
    <div className="cv-user__status cv-user__steer" data-steer={steer} aria-live="polite">
      <span className="cv-user__steer-label">
        {t(steer === "waiting" ? "steer.waiting" : steer === "landed" ? "steer.landed" : "steer.stopped")}
      </span>
      {steer === "waiting" && <span>{t("steer.waitingDetail")}</span>}
    </div>
  );
}
