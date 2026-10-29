// A compact transcript disclosure shared by sub-sessions and incoming messages. The line stays
// anchored while its light panel grows below it (conversation/useAnchoredCollapse.ts).
import { useId, type ReactNode } from "react";
import type { AcpmuxActivity } from "../model";
import { useFindReveal } from "../conversation/chatFind";
import { ChevronRight } from "../conversation/icons";
import { useTranscriptDisclosure } from "../conversation/transcriptDisclosure";
import { useAnchoredCollapse } from "../conversation/useAnchoredCollapse";
import "./DisclosureRow.css";

export type DisclosureRowProps = {
  /// Stable row identity; the transcript provider scopes it to the parent session.
  disclosureKey: string;
  /// Indexed activities enclosed by this panel; Find opens each matching ancestor and child.
  findItems?: readonly AcpmuxActivity[];
  icon: ReactNode;
  label: ReactNode;
  meta?: ReactNode;
  status?: ReactNode;
  openLabel?: string;
  onOpen?: () => void;
  children?: ReactNode;
  defaultOpen?: boolean;
};

export function DisclosureRow({
  disclosureKey,
  findItems = [],
  icon,
  label,
  meta,
  status,
  openLabel,
  onOpen,
  children,
  defaultOpen = false,
}: DisclosureRowProps) {
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, defaultOpen);
  // Search opens directly: anchoring here would fight Find's scroll to the selected match.
  useFindReveal(findItems, () => setOpen(true));
  const collapse = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const bodyId = useId();
  return (
    <div className="cv-disclosure" data-open={collapse.open || undefined}>
      <div className="cv-disclosure__line">
        <button
          ref={collapse.headerRef}
          type="button"
          className="cv-disclosure__toggle"
          aria-expanded={collapse.open}
          aria-controls={collapse.present ? bodyId : undefined}
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
          <button type="button" className="cv-disclosure__open" onClick={onOpen}>
            {openLabel}
          </button>
        )}
      </div>
      {collapse.present && (
        <div id={bodyId} {...collapse.bodyProps}>
          <div className="cv-disclosure__panel">{children}</div>
        </div>
      )}
    </div>
  );
}
