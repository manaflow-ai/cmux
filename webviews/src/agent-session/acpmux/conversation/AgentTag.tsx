import type { ReactNode } from "react";
import "./AgentTag.css";

/** A compact agent or lane name tag shared by transcript activity rows. */
export function AgentTag({
  name,
  title,
  onClick,
  ariaLabel,
  className,
}: {
  name: ReactNode;
  title?: string;
  onClick?(): void;
  ariaLabel?: string;
  className?: string;
}) {
  const classes = `cv-agent-tag${className ? ` ${className}` : ""}`;
  if (onClick) {
    return (
      <button
        type="button"
        className={classes}
        title={title}
        aria-label={ariaLabel}
        data-interactive=""
        onClick={onClick}
      >
        {name}
      </button>
    );
  }
  return (
    <span className={`${classes} is-plain`} title={title} data-interactive="" aria-hidden="true">
      {name}
    </span>
  );
}
