// One agent's name and icon, as a person reads it (Leo, 2026-11-22: "BUT WHO IS MANGO? ... RENAMES
// NEED TO BE PROPAGATED TO THE VISIBLE AREAS ... SET CUSTOM ICONS FOR YOURSELVES IN THE TABS ...
// MAYBE JUST... FKA/ALIASES? ... HUMAN-VISIBLE OUGHT TO BE EASILY LEGIBLE AND ERGONOMIC").
//
// Everything it shows is acpmux's: the name it was given (`displayName`, else the chat's title),
// the icon it set (`icon`, drawn by the harness icon renderer, shared/AgentMark.tsx `SessionMark`),
// else its harness's mark, and the names it had before (`formerNames`, oldest first). It decides
// nothing: "fka" is the newest former name that is not the name shown now, and the tooltip lists
// them all, newest first.
import type { ReactNode } from "react";
import { SessionMark } from "../shared/AgentMark";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import { useT } from "./i18n";
import "./AgentIdentityChip.css";

/** Where the former name shows: only in the tooltip, after the name in muted ink, or under it. */
export type FkaTreatment = "tooltip" | "inline" | "stacked";

/** The default: legible at a glance without a hover, and one line high, so it fits a header and a
 *  sender line alike (a stacked line needs a second row neither has). */
export const DEFAULT_FKA: FkaTreatment = "inline";

/** The newest of `formerNames` that is not `name`, if any. */
export function newestFormerName(name: string, formerNames: readonly string[] | undefined): string | undefined {
  if (!formerNames) return undefined;
  for (let at = formerNames.length - 1; at >= 0; at--) {
    const former = formerNames[at]!.trim();
    if (former && former !== name) return former;
  }
  return undefined;
}

export function AgentIdentityChip({
  name,
  icon,
  harness,
  formerNames,
  fka = DEFAULT_FKA,
  size = 14,
  mark = true,
  title,
  className,
  onDoubleClick,
  children,
}: {
  name: string;
  /** The icon the chat set (acpmux `icon`); none draws `harness`'s mark. */
  icon?: HarnessIconSpec;
  harness?: string;
  /** acpmux `formerNames`, oldest first. */
  formerNames?: readonly string[];
  fka?: FkaTreatment;
  size?: number;
  /** Off: the name alone (a row that draws the mark in its own column). */
  mark?: boolean;
  /** The tooltip's first line (the former names follow it). */
  title?: string;
  className?: string;
  onDoubleClick?: () => void;
  /** After the name, on its line (a host, a status). */
  children?: ReactNode;
}) {
  const t = useT();
  const former = newestFormerName(name, formerNames);
  const all = formerNames
    ?.map((value) => value.trim())
    .filter((value) => value && value !== name)
    .reverse();
  const formerly = all?.length ? t("identity.formerly", { names: [...new Set(all)].join(", ") }) : undefined;
  const tooltip = [title, formerly].filter(Boolean).join("\n") || undefined;
  return (
    <span
      className={`acpmux-identity${className ? ` ${className}` : ""}`}
      data-fka={former ? fka : undefined}
      title={tooltip}
      onDoubleClick={onDoubleClick}
    >
      {mark && (icon || harness) && <SessionMark icon={icon} agent={harness} size={size} />}
      <span className="acpmux-identity__text">
        <span className="acpmux-identity__name">{name}</span>
        {former && fka !== "tooltip" && (
          <span className="acpmux-identity__fka">{t("identity.fka", { name: former })}</span>
        )}
      </span>
      {children}
    </span>
  );
}
