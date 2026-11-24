import { useId, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { Clock } from "./icons";
import { ROW_ICON } from "./messageActionsModel";
import { isEmptyFooter } from "./turns";
import { type WaterfallLook, TurnWaterfall } from "./TurnWaterfall";

/// The footer's Timeline toggle and, while it is open, the waterfall under the footer row. Null for
/// a footer whose turn timed no call.
export function useTurnWaterfall(
  row: AcpmuxRow,
  look: WaterfallLook = "bars",
): { toggle: ReactNode; panel: ReactNode } {
  const t = useT();
  const [open, setOpen] = useState(false);
  const id = useId();
  // An empty footer is a turn gap with no line of its own (turns.ts isEmptyFooter, height 0), which
  // has no room to open a panel under; only a footer that draws its row offers the Timeline.
  if (!row.turnWork?.length || isEmptyFooter(row)) return { toggle: null, panel: null };
  const label = open ? t("turn.timeline.hide") : t("turn.timeline.show");
  return {
    toggle: (
      <button
        type="button"
        className={`cv-iconbtn cv-iconbtn--compact cv-waterfall-toggle${open ? " is-open" : ""}`}
        aria-label={label}
        title={label}
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((now) => !now)}
      >
        <Clock size={ROW_ICON} />
      </button>
    ),
    panel: open ? <TurnWaterfall id={id} row={row} work={row.turnWork} look={look} /> : null,
  };
}
