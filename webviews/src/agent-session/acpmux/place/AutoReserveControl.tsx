import { intl } from "../../../ui/intl";
import { Button } from "../../../ui/Button";
import { Switch } from "../../../ui/Switch";
import { currentLanguage, useT, type StringKey, type Translate } from "../i18n";
import {
  RESERVE_STOPS,
  poolLevel,
  snapReserve,
  type AutoReserveState,
  type LastMove,
  type MoveReason,
} from "./autoReserveModel";
import "./autoReserve.css";

const percent = (share: number) => intl.NumberFormat(currentLanguage(), { style: "percent" }).format(share);
const clock = (atMs: number) =>
  intl.DateTimeFormat(currentLanguage(), { hour: "numeric", minute: "2-digit" }).format(atMs);

const REASONS: Record<MoveReason, StringKey> = {
  cpu: "autoReserve.reasonCpu",
  memory: "autoReserve.reasonMemory",
  heat: "autoReserve.reasonHeat",
};

/// The chip on a moved chat: "Moved to Cloud: Mac was busy, 11:02".
export function movedChipText(move: Pick<LastMove, "reason" | "atMs">, t: Translate): string {
  return t("autoReserve.chip", { reason: t(REASONS[move.reason]), time: clock(move.atMs) });
}

export function MovedChip({ move }: { move: Pick<LastMove, "reason" | "atMs"> }) {
  const t = useT();
  return (
    <span className="acpmux-reserve-chip" data-testid="reserve-chip">
      {movedChipText(move, t)}
    </span>
  );
}

/// The one line in the Auto control: the last move and its reason, or that nothing moved yet.
export function lastMoveText(move: LastMove | undefined, t: Translate): string {
  if (!move) return t("autoReserve.noMove");
  return t(move.state === "moving" ? "autoReserve.moving" : "autoReserve.lastMove", {
    title: move.title,
    reason: t(REASONS[move.reason]),
    time: clock(move.atMs),
  });
}

/// Auto: the switch (`cloud.auto`), the share kept for the person (`cloud.autoReserve`, four stops), the
/// last move with its reason and one click to undo it, and the pool when it nears its ceiling. No dialog.
/// Standalone gallery prototype; a settings/action adapter must connect it to the daemon.
export function AutoReserveControl({
  reserve,
  onChange,
  onBringBack,
  onCancel,
}: {
  reserve: AutoReserveState;
  onChange(next: { on: boolean; keep: number }): void;
  /// Bring Back the last moved chat; hidden when not given.
  onBringBack?(): void;
  /// Cancel a move still under way; hidden when not given.
  onCancel?(): void;
}) {
  const t = useT();
  const keepLabel = t("autoReserve.keep");
  const level = poolLevel(reserve.pool);
  const move = reserve.lastMove;
  const keep = snapReserve(reserve.keep);
  const stopIndex = RESERVE_STOPS.indexOf(keep as (typeof RESERVE_STOPS)[number]);
  return (
    <div className="acpmux-reserve" data-on={reserve.on ? "true" : undefined}>
      <label className="acpmux-reserve-toggle">
        <Switch
          size="sm"
          checked={reserve.on}
          onCheckedChange={(on) => onChange({ on, keep })}
          data-testid="reserve-on"
        />
        <span>{t("autoReserve.toggle")}</span>
      </label>
      <div className="acpmux-reserve-keep">
        <span className="acpmux-reserve-keep-label">{keepLabel}</span>
        <div className="acpmux-reserve-slider">
          <input
            type="range"
            min={0}
            max={RESERVE_STOPS.length - 1}
            step={1}
            aria-label={keepLabel}
            aria-valuetext={percent(keep)}
            value={stopIndex}
            disabled={!reserve.on}
            data-testid="reserve-slider"
            onChange={(event) => onChange({ on: reserve.on, keep: RESERVE_STOPS[Number(event.target.value)] ?? 0.5 })}
          />
          <div className="acpmux-reserve-ticks" aria-hidden="true">
            {RESERVE_STOPS.map((stop) => (
              <span key={stop} data-on={keep === stop ? "true" : undefined}>
                {percent(stop)}
              </span>
            ))}
          </div>
        </div>
      </div>
      {reserve.on && (
        <div className="acpmux-reserve-line">
          <span className="acpmux-reserve-line-text" data-testid="reserve-last-move">
            {lastMoveText(move, t)}
          </span>
          {move?.state === "moved" && onBringBack && (
            <Button size="sm" variant="ghost" data-testid="reserve-bring-back" onClick={onBringBack}>
              {t("autoReserve.bringBack")}
            </Button>
          )}
          {move?.state === "moving" && onCancel && (
            <Button size="sm" variant="ghost" data-testid="reserve-cancel" onClick={onCancel}>
              {t("autoReserve.cancel")}
            </Button>
          )}
        </div>
      )}
      {reserve.on && level !== "ok" && reserve.pool !== undefined && (
        <span className="acpmux-reserve-pool" data-level={level} data-testid="reserve-pool">
          {level === "ceiling" ? t("autoReserve.ceiling") : t("autoReserve.pool", { percent: percent(reserve.pool) })}
        </span>
      )}
    </div>
  );
}
