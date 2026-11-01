import type { MouseEvent, ReactNode } from "react";
import { ArrowUpRight } from "./icons";
import "./AgentTag.css";

/** A compact agent or lane name tag shared by transcript activity rows. One that opens a chat is a
 *  link chip: the link colour, real padding and an open cue (↗), lit on its own on hover, never
 *  with its row (Leo, 2026-11-01: "this highlight is both not aligned with the icon vertically and
 *  too small and also not prominent enough because the whole line gets highlighted and it's not
 *  obvious that clicking on this will be a new thing"). */
export function AgentTag({
  name,
  title,
  onClick,
  ariaLabel,
  className,
}: {
  name: ReactNode;
  title?: string;
  onClick?(event: MouseEvent<HTMLButtonElement>): void;
  ariaLabel?: string;
  className?: string;
}) {
  const classes = `cv-agent-tag${className ? ` ${className}` : ""}`;
  if (onClick) {
    return (
      <button
        type="button"
        className={`${classes} is-open`}
        title={title}
        aria-label={ariaLabel}
        data-interactive=""
        onClick={onClick}
      >
        <span className="cv-agent-tag__label">{name}</span>
        <ArrowUpRight size={12} strokeWidth={1.4} className="cv-agent-tag__cue" />
      </button>
    );
  }
  return (
    <span className={`${classes} is-plain`} title={title} data-interactive="" aria-hidden="true">
      {name}
    </span>
  );
}
