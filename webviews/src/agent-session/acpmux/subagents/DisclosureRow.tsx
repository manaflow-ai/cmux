// A compact transcript disclosure shared by sub-sessions and incoming messages. The line stays
// anchored while its light panel grows below it (conversation/useAnchoredCollapse.ts).
// A caller that keeps its own open state (an incoming message, whose state the row estimate reads,
// incomingOpened.ts) passes `open` and `onOpenChange` in place of `disclosureKey`; `actions` sit after
// the toggle, outside its button, for the controls a row adds at the line's end (a menu, a queue tag,
// Reply).
import { useCallback, useId, type ReactNode } from "react";
import type { AcpmuxActivity } from "../model";
import { useFindReveal } from "../conversation/chatFind";
import { ChevronRight } from "../conversation/icons";
import { useTranscriptDisclosure } from "../conversation/transcriptDisclosure";
import { useAnchoredCollapse } from "../conversation/useAnchoredCollapse";
import "./DisclosureRow.css";

export type DisclosureRowProps = {
  /// Stable row identity; the transcript provider scopes it to the parent session. Unused when the
  /// caller holds `open`.
  disclosureKey?: string;
  /// Indexed activities enclosed by this panel; Find opens each matching ancestor and child.
  findItems?: readonly AcpmuxActivity[];
  icon: ReactNode;
  label: ReactNode;
  meta?: ReactNode;
  status?: ReactNode;
  openLabel?: string;
  /// The open button's tooltip, when it says more than `openLabel` (its accessible name).
  openTitle?: string;
  onOpen?: () => void;
  children?: ReactNode;
  defaultOpen?: boolean;
  /// The state, when the caller holds it.
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /// Whether a change plays the fold (default: every one).
  animates?: () => boolean;
  /// Whether opening fades the panel in (default: yes); false moves its height alone.
  fadeIn?: boolean;
  /// The toggle's accessible name, when its visible label alone does not read well.
  toggleLabel?: string;
  /// After the toggle, outside its button.
  actions?: ReactNode;
  /// The row's own class, next to `cv-disclosure`.
  className?: string;
};

export function DisclosureRow({
  disclosureKey = "",
  findItems = [],
  icon,
  label,
  meta,
  status,
  openLabel,
  openTitle,
  onOpen,
  children,
  defaultOpen = false,
  open,
  onOpenChange,
  animates,
  fadeIn,
  toggleLabel,
  actions,
  className,
}: DisclosureRowProps) {
  const [stored, setStored] = useTranscriptDisclosure(disclosureKey, defaultOpen);
  const held = open !== undefined;
  const setOpen = useCallback(
    (next: boolean) => {
      if (!held) setStored(next);
      onOpenChange?.(next);
    },
    [held, setStored, onOpenChange],
  );
  // Search opens directly: anchoring here would fight Find's scroll to the selected match.
  useFindReveal(findItems, () => setOpen(true));
  const collapse = useAnchoredCollapse({ open: held ? open : stored, onOpenChange: setOpen, animates, fadeIn });
  const bodyId = useId();
  return (
    <div className={className ? `cv-disclosure ${className}` : "cv-disclosure"} data-open={collapse.open || undefined}>
      {/* The line summarizes indexed content in the panel; it adds no Find occurrences. */}
      <div className="cv-disclosure__line" data-find-skip>
        <button
          ref={collapse.headerRef}
          type="button"
          className="cv-disclosure__toggle"
          aria-expanded={collapse.open}
          aria-controls={collapse.present ? bodyId : undefined}
          aria-label={toggleLabel}
          onClick={collapse.toggle}
        >
          <span className="cv-disclosure__icon" aria-hidden="true">
            {icon}
          </span>
          <span className="cv-disclosure__label">{label}</span>
          {meta && <span className="cv-disclosure__meta">{meta}</span>}
          {status && <span className="cv-disclosure__status">{status}</span>}
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${collapse.open ? " is-open" : ""}`} />
        </button>
        {onOpen && (
          <button type="button" className="cv-disclosure__open" title={openTitle} onClick={onOpen}>
            {openLabel}
          </button>
        )}
        {actions}
      </div>
      {collapse.present && (
        <div id={bodyId} {...collapse.bodyProps}>
          <div className="cv-disclosure__panel">{children}</div>
        </div>
      )}
    </div>
  );
}
