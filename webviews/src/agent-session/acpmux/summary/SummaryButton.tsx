import React, { useMemo } from "react";
import { t } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { sessionSummary } from "./sessionSummary";
import { SummaryPopover } from "./SummaryPopover";
import { usePopover } from "./usePopover";

/// The header's summary button and its popover: what this chat has produced so far. The
/// summary is read from the transcript only while the popover is open, so a live turn pays
/// nothing for it while it is closed.
export function SummaryButton({
  rows,
  onOpenOutput,
}: {
  rows: readonly AcpmuxRow[];
  onOpenOutput?: (path: string) => void;
}) {
  const { open, setOpen, button, popover, toggle } = usePopover();
  const summary = useMemo(() => (open ? sessionSummary(rows) : undefined), [open, rows]);
  return (
    <span className="acpmux-summary">
      <button
        ref={button}
        type="button"
        className="acpmux-summary-button"
        aria-label={t("summary.open")}
        title={t("summary.open")}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={toggle}
      >
        <Icon name="view.list" size={15} />
      </button>
      {open && summary && (
        <dialog ref={popover} open tabIndex={-1} aria-label={t("summary.open")} className="acpmux-summary-popover">
          <SummaryPopover
            summary={summary}
            onOpenOutput={
              onOpenOutput &&
              ((path) => {
                setOpen(false);
                onOpenOutput(path);
              })
            }
          />
        </dialog>
      )}
    </span>
  );
}
