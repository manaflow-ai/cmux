import { useT } from "../i18n";
import { usePageNow } from "../../../ui/pageClock";
import { capacityEta, capacityProgress, type CapacityWaitState } from "../capacityWait";
import { ErrorDetails } from "./ErrorDetails";
import { Clock, Spinner } from "./icons";

export type CapacityWaitLook = "line" | "card" | "bar";

/// A turn acpmux holds for capacity, where its failed card would be (RFD model-overload-smoothing
/// §3.8; Leo, 2026-11-24: "fix 529s properly with better designs"). One calm state with a live
/// countdown from acpmux's resume time, "Waiting for capacity, about 40s"; the harness's raw error
/// under Details only. Never the failure red: red is a turn nothing will continue.
export function CapacityWaitCard({
  wait,
  look,
  now: fixedNow,
}: {
  wait: CapacityWaitState;
  look: CapacityWaitLook;
  /** A fixed clock, for the gallery. */
  now?: number;
}) {
  const t = useT();
  const liveNow = usePageNow(fixedNow === undefined);
  const now = fixedNow ?? liveNow;
  const eta = capacityEta(t, wait, now);
  const progress = look === "bar" ? capacityProgress(wait, now) : undefined;
  return (
    <div className={`cv-turn-note cv-capacity-wait cv-capacity-wait--${look}`} data-capacity-reason={wait.reason}>
      {/* Only the countdown is a live status; Details sits outside it. */}
      <output className="cv-capacity-wait__line">
        {look === "card" ? (
          <Clock size={16} className="cv-capacity-wait__icon" />
        ) : (
          <Spinner size={14} look="track" className="cv-capacity-wait__icon" />
        )}
        <span className="text-fg">{eta}</span>
      </output>
      {progress !== undefined && (
        <span className="cv-capacity-wait__track" aria-hidden="true">
          <span className="cv-capacity-wait__bar">
            <span className="cv-capacity-wait__fill" style={{ inlineSize: `${Math.round(progress * 100)}%` }} />
          </span>
        </span>
      )}
      {(look === "card" || wait.error) && (
        <span className="cv-capacity-wait__more">
          {look === "card" && <span className="text-detail text-dim">{t("capacity.wait.goesOn")}</span>}
          {wait.error && <ErrorDetails text={wait.error} />}
        </span>
      )}
    </div>
  );
}
