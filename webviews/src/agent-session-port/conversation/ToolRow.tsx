import type { ReactNode } from "react";
import { disclosureProps } from "./disclosure";
import { ChevronDown, ChevronRight, Globe } from "./icons";

export type ToolRowProps = {
  /** Leading icon; `"globe"` for web search; omitted for none. */
  icon?: ReactNode | "globe";
  children: ReactNode;
  /** Dim query part after the verb ("for …"). */
  detail?: ReactNode;
  /** Trailing chevron (expandable group). `hover` shows a right chevron on hover only. */
  chevron?: "down" | "right" | "hover";
  /** Settled summary rows are brighter than live progress rows. */
  tone?: "dim" | "strong";
  /** Makes the row a disclosure button (group header, command, tool call, diff). */
  onToggle?: () => void;
  /** Trailing content after the text ("+12 -2"). */
  trailing?: ReactNode;
  /** Text shimmer of a live row. */
  live?: boolean;
  /** Scroll anchor key (`data-anchor`). */
  anchor?: string;
};

/** Tool / progress row: "Searched the web", "Planning …", "Used the browser and …". */
export function ToolRow({
  icon,
  children,
  detail,
  chevron,
  tone = "dim",
  onToggle,
  trailing,
  live,
  anchor,
}: ToolRowProps) {
  const open = chevron === "down";
  return (
    <div
      data-anchor={anchor}
      className={`cv-tool${tone === "strong" ? " is-strong" : ""}${onToggle ? " is-toggle" : ""}${live ? " is-live" : ""}`}
      {...disclosureProps(open, onToggle)}
    >
      {icon === "globe" ? (
        <Globe className="cv-tool__icon" size={16} strokeWidth={1.1} />
      ) : (
        icon && <span className="cv-tool__icon">{icon}</span>
      )}
      <span className="cv-tool__text">
        {children}
        {detail && <span className="cv-tool__detail"> {detail}</span>}
      </span>
      {trailing}
      {onToggle && chevron !== undefined ? (
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      ) : (
        <>
          {chevron === "down" && <ChevronDown size={14} strokeWidth={1.2} className="cv-tool__chevron" />}
          {chevron === "right" && <ChevronRight size={14} strokeWidth={1.2} className="cv-tool__chevron" />}
        </>
      )}
    </div>
  );
}
