import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";

/// Under a prompt sent into a running turn (a steer): steered once the agent read it (Claude Code
/// reads it when the step it is on ends; the rest of that reply still streams above it). Until
/// then it shows as any sent prompt: Cmd-Return sent it, and a "Steering" label while it waited
/// made the first press look like it had not (Austin 2026-10-20). A prompt sent now to an agent
/// that cannot steer stopped the turn and ran next.
export function SteerMark({ steer }: { steer: NonNullable<AcpmuxRow["steer"]> }) {
  const t = useT();
  if (steer === "waiting") return null;
  return (
    <div className="cv-user__status cv-user__steer" data-steer={steer} aria-live="polite">
      <span className="cv-user__steer-label">{t(steer === "landed" ? "steer.landed" : "steer.stopped")}</span>
    </div>
  );
}
