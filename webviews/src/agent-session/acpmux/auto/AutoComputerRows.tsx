// RFD 0080: this RFD's rows in RFD 0078's place popover, under its Hybrid / Only in Cloud / Only on
// This Mac choice, Keep running and hours line. Size and Sleep are Auto by default with a manual
// pin; Why is one sentence. Presentation only: every choice is a callback, none decides anything.
import "./computerAuto.css";
import type { ReactNode } from "react";
import { useT } from "../i18n";
import { sizeRow, sleepRow, whyRow, type ComputerStatus } from "./computerStatus";
import { Button } from "../../../ui/Button";
import { Icon } from "../icons/Icon";

export type SleepChoice = { mode: "auto" } | { mode: "keep_awake"; hours: 1 | 4 };

export type AutoComputerRowsProps = {
  status: ComputerStatus;
  /// Renders a clock time; the page passes its locale's.
  formatTime?: (ms: number) => string;
  onAutoSize(): void;
  onPinSize(): void;
  onSleep(choice: SleepChoice): void;
  onOpenTerminal(): void;
  onOpenDetails(): void;
};

const defaultTime = (ms: number) => new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

function PinMark() {
  const t = useT();
  return (
    <Icon name="state.pinned" size={12} selected title={t("computer.size.pinMark")} className="acpmux-computer-pin" />
  );
}

function Choice({ on, onClick, children }: { on: boolean; onClick(): void; children: ReactNode }) {
  return (
    <Button
      bare
      type="button"
      className="acpmux-computer-choice"
      aria-pressed={on}
      data-on={on ? "true" : undefined}
      onClick={onClick}
    >
      {children}
    </Button>
  );
}

function Row({
  label,
  pinned,
  children,
  note,
}: {
  label: string;
  pinned?: boolean;
  children?: ReactNode;
  note?: string;
}) {
  return (
    <div className="acpmux-computer-row">
      <span className="acpmux-computer-row-label">
        {label}
        {pinned ? <PinMark /> : null}
      </span>
      {children ? <span className="acpmux-computer-row-choices">{children}</span> : null}
      {note ? <span className="acpmux-computer-row-note">{note}</span> : null}
    </div>
  );
}

export function AutoComputerRows({
  status,
  formatTime = defaultTime,
  onAutoSize,
  onPinSize,
  onSleep,
  onOpenTerminal,
  onOpenDetails,
}: AutoComputerRowsProps) {
  const t = useT();
  const size = sizeRow(status, t);
  const sleep = sleepRow(status, t, formatTime);
  const why = whyRow(status, t, formatTime);
  const keeping = status.sleep.mode === "keep_awake";
  return (
    <div className="acpmux-computer-rows" data-testid="computer-rows">
      <Row label={t("computer.row.size")} pinned={size.pinned} note={size.note}>
        <Choice on={size.auto} onClick={onAutoSize}>
          {t("computer.size.auto")}
        </Choice>
        <Choice on={size.pinned} onClick={onPinSize}>
          {t("computer.size.pin")}
        </Choice>
      </Row>
      <Row label={t("computer.row.sleep")} pinned={keeping} note={sleep.note}>
        <Choice on={!keeping} onClick={() => onSleep({ mode: "auto" })}>
          {t("computer.sleep.auto")}
        </Choice>
        <span className="acpmux-computer-choice-label">{t("computer.sleep.keepAwake")}</span>
        <Choice on={false} onClick={() => onSleep({ mode: "keep_awake", hours: 1 })}>
          {t("computer.sleep.oneHour")}
        </Choice>
        <Choice on={false} onClick={() => onSleep({ mode: "keep_awake", hours: 4 })}>
          {t("computer.sleep.fourHours")}
        </Choice>
      </Row>
      {why ? <Row label={t("computer.row.why")} note={why} /> : null}
      <div className="acpmux-computer-buttons">
        <Button bare type="button" className="acpmux-computer-button" onClick={onOpenTerminal}>
          {t("computer.openTerminal")}
        </Button>
        <Button bare type="button" className="acpmux-computer-button" onClick={onOpenDetails}>
          {t("computer.details")} <span aria-hidden="true">▸</span>
        </Button>
      </div>
    </div>
  );
}
