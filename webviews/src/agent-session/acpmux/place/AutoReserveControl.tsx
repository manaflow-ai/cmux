import { intl } from "../../../ui/intl";
import { Switch } from "../../../ui/Switch";
import { currentLanguage, useT, type Translate } from "../i18n";
import { RESERVE_STOPS, type AutoReserveState, type ReserveShadow } from "./placeModel";
import "./place.css";

/// How the control draws (AutoReserveControl.gallery.tsx compares them): `stops`, the switch and the
/// four stops as one segmented row; `slider`, the switch over a slider with its stops marked;
/// `card`, the slider plus the last thing Auto would have moved and why.
export type AutoReserveLook = "stops" | "slider" | "card";

const percent = (keep: number) => intl.NumberFormat(currentLanguage(), { style: "percent" }).format(keep);

/// The last would-be move, in one line. Stage 1 (RFD 0072) moves nothing, so it says "would have".
export function shadowLine(shadow: ReserveShadow | undefined, t: Translate): string {
  if (!shadow) return t("placeReserve.noneYet");
  const time = intl.DateTimeFormat(currentLanguage(), { hour: "numeric", minute: "2-digit" }).format(shadow.atMs);
  return t(shadow.reason === "memory" ? "placeReserve.wouldMoveMemory" : "placeReserve.wouldMoveCpu", {
    title: shadow.title,
    time,
  });
}

/// Auto on reserve: the person keeps a share of this Mac, and Auto moves an agent to its own Cloud VM
/// only while agents use more than the rest. The rule and its verdict are Rust's (cmux-host-budget
/// `reserve.rs`); this draws the setting (`cloud.auto`, `cloud.autoReserve`) and the last verdict.
export function AutoReserveControl({
  reserve,
  look = "stops",
  onChange,
}: {
  reserve: AutoReserveState;
  look?: AutoReserveLook;
  onChange(next: { on: boolean; keep: number }): void;
}) {
  const t = useT();
  const keepLabel = t("placeReserve.keep");
  const toggle = (
    <label className="acpmux-reserve-toggle">
      <Switch
        size="sm"
        checked={reserve.on}
        onCheckedChange={(on) => onChange({ on, keep: reserve.keep })}
        data-testid="reserve-on"
      />
      <span>{t("placeReserve.toggle")}</span>
    </label>
  );
  const stops = (
    <div className="acpmux-place-seg acpmux-reserve-stops" role="radiogroup" aria-label={keepLabel}>
      {RESERVE_STOPS.map((keep) => (
        <button
          key={keep}
          type="button"
          role="radio"
          aria-checked={reserve.keep === keep}
          className="acpmux-place-segbtn"
          data-testid={`reserve-keep-${keep}`}
          data-on={reserve.keep === keep ? "true" : undefined}
          disabled={!reserve.on}
          onClick={() => onChange({ on: reserve.on, keep })}
        >
          {percent(keep)}
        </button>
      ))}
    </div>
  );
  const slider = (
    <div className="acpmux-reserve-slider">
      <input
        type="range"
        min={0}
        max={RESERVE_STOPS.length - 1}
        step={1}
        list="acpmux-reserve-ticks"
        aria-label={keepLabel}
        aria-valuetext={percent(reserve.keep)}
        value={Math.max(0, RESERVE_STOPS.indexOf(reserve.keep as (typeof RESERVE_STOPS)[number]))}
        disabled={!reserve.on}
        data-testid="reserve-slider"
        onChange={(event) => onChange({ on: reserve.on, keep: RESERVE_STOPS[Number(event.target.value)] ?? 0.5 })}
      />
      <div className="acpmux-reserve-ticks" aria-hidden="true">
        {RESERVE_STOPS.map((keep) => (
          <span key={keep} data-on={reserve.keep === keep ? "true" : undefined}>
            {percent(keep)}
          </span>
        ))}
      </div>
    </div>
  );
  return (
    <div className="acpmux-reserve" data-look={look} data-on={reserve.on ? "true" : undefined}>
      {toggle}
      <div className="acpmux-reserve-keep">
        <span className="acpmux-reserve-keep-label">{keepLabel}</span>
        {look === "stops" ? stops : slider}
      </div>
      {reserve.on && <span className="acpmux-place-rule">{t("placeReserve.trial")}</span>}
      {look === "card" && reserve.on && (
        <span className="acpmux-reserve-shadow" data-testid="reserve-shadow">
          {shadowLine(reserve.shadow, t)}
        </span>
      )}
    </div>
  );
}
