import type { ReactNode } from "react";
import { disclosureProps } from "./disclosure";
import { ChevronDown, ChevronRight } from "./icons";

export type WorkedForProps = {
  /** Full label: "Worked for 1m 16s", "Working for 42s", "You stopped after 0s". */
  label: ReactNode;
  /** Chevron: `right` collapsed, `down` expanded, `false` none (live state). */
  chevron?: "right" | "down" | false;
  /** Hairline under the row. */
  divider?: boolean;
  /** Makes the row a disclosure button; the chevron then rotates instead of swapping. */
  onToggle?: () => void;
  /** Scroll anchor key (`data-anchor`). */
  anchor?: string;
};

/** "Worked for Xm Ys" summary row that opens the turn's activity log. */
export function WorkedFor({ label, chevron = "right", divider = true, onToggle, anchor }: WorkedForProps) {
  return (
    <div
      data-anchor={anchor}
      className={`cv-worked${divider ? " has-divider" : ""}${chevron === false ? " is-live" : ""}${onToggle ? " is-toggle" : ""}`}
      {...disclosureProps(chevron === "down", onToggle)}
    >
      <span className="cv-worked__label">{label}</span>
      {onToggle && chevron !== false ? (
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-worked__chevron cv-rotor${chevron === "down" ? " is-open" : ""}`}
        />
      ) : (
        <>
          {chevron === "right" && <ChevronRight size={14} strokeWidth={1.2} className="cv-worked__chevron" />}
          {chevron === "down" && <ChevronDown size={14} strokeWidth={1.2} className="cv-worked__chevron" />}
        </>
      )}
    </div>
  );
}
