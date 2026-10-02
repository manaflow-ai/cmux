// Transcript rows: user bubble, assistant turn, turn actions, timestamp, Worked-for row,
// tool/progress rows and the streaming "Thinking" label.
import type { CSSProperties, ReactNode } from "react";
import { disclosureProps } from "./disclosure";
import { IconButton } from "./buttons";
import {
  ChevronDown,
  ChevronRight,
  Copy,
  Globe,
  Pencil,
  TurnAnchor,
  TurnCopy,
  TurnFork,
} from "./icons";

/* ---------------- User ---------------- */

export type UserMessageProps = {
  children: ReactNode;
  /** Copy / edit buttons under the bubble (shown on hover or after a stop; the row's space is always reserved). */
  actions?: boolean;
};

/** Right-aligned user bubble (max 70% of the column). */
export function UserMessage({ children, actions = false }: UserMessageProps) {
  return (
    <div className="cv-user">
      <div className="cv-user__bubble">{children}</div>
      <div className="cv-user__actions">
        {actions && (
          <>
            <IconButton label="Copy message">
              <Copy />
            </IconButton>
            <IconButton label="Edit message">
              <Pencil />
            </IconButton>
          </>
        )}
      </div>
    </div>
  );
}

/* ---------------- Assistant ---------------- */

/**
 * Buttons closing an assistant turn: `copy` (copy only), `fork` (copy, fork), `full` (copy, fork, anchor) or
 * `hidden` (Codex reserves the row's height while the buttons are hidden).
 */
export type TurnActionsKind = "copy" | "fork" | "full" | "hidden";

export function TurnActions({ kind }: { kind: TurnActionsKind }) {
  if (kind === "fork") {
    // Copy and "Fork chat from here" (a completed local turn, live captures).
    return (
      <div className="cv-turn-actions is-full">
        <IconButton label="Copy">
          <TurnCopy />
        </IconButton>
        <IconButton label="Fork chat from here">
          <TurnFork />
        </IconButton>
      </div>
    );
  }
  if (kind === "full") {
    return (
      <div className="cv-turn-actions is-full">
        <IconButton label="Copy">
          <TurnCopy />
        </IconButton>
        <IconButton label="Fork from here">
          <TurnFork />
        </IconButton>
        <IconButton label="Pin">
          <TurnAnchor />
        </IconButton>
      </div>
    );
  }
  return (
    <div className={`cv-turn-actions${kind === "hidden" ? " is-hidden" : ""}`}>
      <IconButton label="Copy">
        <Copy />
      </IconButton>
    </div>
  );
}

/** Assistant turn wrapper; `actions` closes the turn with its button row. */
export function AssistantMessage({
  children,
  actions,
}: {
  children: ReactNode;
  actions?: TurnActionsKind;
}) {
  return (
    <div className="cv-assistant">
      {children}
      {actions && <TurnActions kind={actions} />}
    </div>
  );
}

/** Timestamp separator ("Sun, Sep 13 at 7:55 PM"). */
export function Timestamp({ children }: { children: ReactNode }) {
  return <div className="cv-timestamp">{children}</div>;
}

/* ---------------- Worked for ---------------- */

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
export function WorkedFor({
  label,
  chevron = "right",
  divider = true,
  onToggle,
  anchor,
}: WorkedForProps) {
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
          {chevron === "right" && (
            <ChevronRight size={14} strokeWidth={1.2} className="cv-worked__chevron" />
          )}
          {chevron === "down" && (
            <ChevronDown size={14} strokeWidth={1.2} className="cv-worked__chevron" />
          )}
        </>
      )}
    </div>
  );
}

/* ---------------- Tool rows ---------------- */

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
          {chevron === "down" && (
            <ChevronDown size={14} strokeWidth={1.2} className="cv-tool__chevron" />
          )}
          {chevron === "right" && (
            <ChevronRight size={14} strokeWidth={1.2} className="cv-tool__chevron" />
          )}
        </>
      )}
    </div>
  );
}

/** Consecutive tool rows; the group owns the spacing to the surrounding text. */
export function ToolGroup({ children }: { children: ReactNode }) {
  return <div className="cv-tools">{children}</div>;
}

/* ---------------- Thinking ---------------- */

export type ThinkingProps = {
  label?: string;
  /**
   * Center of the moving highlight as a fraction of the label width (0…1). The capture
   * froze it over "ing" (0.88); `null` draws the label flat.
   */
  shimmer?: number | null;
  /** Half-width of the highlight ramp, as a fraction of the label width. */
  spread?: number;
};

/** Streaming "Thinking" label with its moving highlight frozen at `shimmer`. */
export function Thinking({ label = "Thinking", shimmer = 0.88, spread = 0.28 }: ThinkingProps) {
  const style =
    shimmer === null
      ? undefined
      : ({
          "--cv-shimmer": `${(shimmer * 100).toFixed(1)}%`,
          "--cv-shimmer-from": `${((shimmer - spread) * 100).toFixed(1)}%`,
          "--cv-shimmer-to": `${((shimmer + spread) * 100).toFixed(1)}%`,
        } as CSSProperties);
  return (
    <div className="cv-thinking-row">
      <span className={`cv-thinking${shimmer === null ? "" : " is-shimmer"}`} style={style}>
        {label}
      </span>
    </div>
  );
}
