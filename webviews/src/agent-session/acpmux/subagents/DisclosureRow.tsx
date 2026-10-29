// A compact transcript disclosure shared by sub-sessions and incoming messages. The line stays
// anchored while its light panel grows below it (conversation/useAnchoredCollapse.ts).
// A caller that keeps its own open state (an incoming message, whose state outlives the virtualized
// row) passes `open` and `onOpenChange`; `actions` sit after the toggle, outside its button, for the
// controls a row adds at the line's end (a menu, a queue tag, Reply).
import { useId, type ReactNode } from "react";
import { ChevronRight } from "../conversation/icons";
import { useAnchoredCollapse } from "../conversation/useAnchoredCollapse";
import "./DisclosureRow.css";

export type DisclosureRowProps = {
  icon: ReactNode;
  label: ReactNode;
  meta?: ReactNode;
  status?: ReactNode;
  openLabel?: string;
  onOpen?: () => void;
  children?: ReactNode;
  defaultOpen?: boolean;
  /// The state, when the caller holds it.
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /// Whether a change plays the fold (default: every one).
  animates?: () => boolean;
  /// The toggle's accessible name, when its visible label alone does not read well.
  toggleLabel?: string;
  /// After the toggle, outside its button.
  actions?: ReactNode;
  /// The row's own class, next to `cv-disclosure`.
  className?: string;
};

export function DisclosureRow({
  icon,
  label,
  meta,
  status,
  openLabel,
  onOpen,
  children,
  defaultOpen = false,
  open,
  onOpenChange,
  animates,
  toggleLabel,
  actions,
  className,
}: DisclosureRowProps) {
  const collapse = useAnchoredCollapse({ defaultOpen, open, onOpenChange, animates });
  const bodyId = useId();
  return (
    <div
      className={className ? `cv-disclosure ${className}` : "cv-disclosure"}
      data-open={collapse.open || undefined}
    >
      <div className="cv-disclosure__line">
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
          <button type="button" className="cv-disclosure__open" onClick={onOpen}>
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
