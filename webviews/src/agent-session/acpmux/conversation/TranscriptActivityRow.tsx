import type { MouseEventHandler, ReactNode, Ref } from "react";
import { ChevronRight } from "./icons";
import { AgentTag } from "./AgentTag";
import "./TranscriptActivityRow.css";

/** The shared one-line grammar for subagent, messaging, and inbox activity. */
export function TranscriptActivityRow({
  icon,
  before,
  name,
  after,
  meta,
  actions,
  onClick,
  ariaLabel,
  className,
  children,
  attributes,
  headerRef,
  expanded = false,
}: {
  icon: ReactNode;
  before?: ReactNode;
  name?: ReactNode;
  after?: ReactNode;
  meta?: ReactNode;
  actions?: ReactNode;
  onClick?(): void;
  ariaLabel?: string;
  className?: string;
  children?: ReactNode;
  attributes?: Record<string, string | undefined>;
  headerRef?: Ref<HTMLButtonElement>;
  expanded?: boolean;
}) {
  const content = (
    <>
      <span className="cv-tool__icon cv-agent-activity__icon">{icon}</span>
      <span className="cv-agent-activity__sentence">
        {before}
        {name !== undefined && <AgentTag name={name} />}
        {after}
        {children}
      </span>
      {meta !== undefined && <span className="cv-tool__trail cv-agent-activity__trail">{meta}</span>}
      <span
        className={`cv-tool__chevron cv-agent-activity__chevron cv-rotor${expanded ? " is-open" : ""}`}
        aria-hidden="true"
      >
        <ChevronRight size={14} strokeWidth={1.2} />
      </span>
    </>
  );
  const classes = `cv-tool cv-agent-activity__control${className ? ` ${className}` : ""}`;
  return (
    <div className="cv-agent-activity-row" aria-label={onClick ? ariaLabel : undefined}>
      {onClick ? (
        <button
          type="button"
          className={classes}
          aria-label={ariaLabel}
          ref={headerRef}
          onClick={onClick}
          {...attributes}
        >
          {content}
        </button>
      ) : (
        <div className={classes} aria-label={ariaLabel} {...attributes}>
          {content}
        </div>
      )}
      {actions}
    </div>
  );
}

/** Shared shell for disclosure rows that keep their own body and controls. */
export function TranscriptActivityRowShell({
  children,
  className,
  attributes,
  headerRef,
  onClick,
}: {
  children: ReactNode;
  className?: string;
  attributes?: Record<string, string | undefined>;
  headerRef?: Ref<HTMLDivElement>;
  onClick?: MouseEventHandler<HTMLDivElement>;
}) {
  // `onClick` is only the pointer's wider target: the whole line toggles, edge to edge, all but its
  // own controls (headerToggle.ts). A caller that passes it puts its own toggle <button> in the line
  // (DisclosureRow, with aria-expanded): that button is the keyboard and screen reader control. So
  // the line takes no focus and no key handler, and `presentation` says the line is not a control.
  return (
    <div
      className={`${className ?? ""}${className ? " " : ""}cv-agent-activity-row`}
      ref={headerRef}
      onClick={onClick}
      role="presentation"
      {...attributes}
    >
      {children}
    </div>
  );
}
