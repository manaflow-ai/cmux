import React, { createContext, useContext } from "react";
import { createPortal } from "react-dom";
import { useT } from "./i18n";
import { tooltipProps } from "./shortcuts";

/// The composer's place for the speed toggle (Leo 2026-10-15: "a lightning-bolt toggle at the
/// bottom right, just left of the mic button"): a `display: contents` span in the trailing
/// cluster, before the mic (Composer.tsx). The chips own the session's speed option, so they draw
/// the toggle into it; a composer without the slot (the New Tab hero's) draws none.
export const SpeedToggleSlot = createContext<HTMLElement | null>(null);

/// The session's speed option (Claude Code's Fast Mode, Codex's service tier): its off value and
/// the faster tiers it offers, in the agent's order (Fast, then Ultrafast where one is offered).
export type SpeedTiers = {
  current?: string;
  off: string;
  tiers: string[];
  /// Sends the pick as the reasoning menu's speed rows do (chat.effort, configId=value).
  onPick(value: string): void;
};

/// The bolt: muted while off, in the accent while a tier runs, filled for a tier past Fast. A click
/// steps to the next offered tier, and from the last one back to off; with one tier it is on/off.
export function FastToggle({ speed }: { speed: SpeedTiers }) {
  const t = useT();
  const slot = useContext(SpeedToggleSlot);
  if (!slot || speed.tiers.length === 0) return null;
  const at = speed.tiers.indexOf(speed.current ?? "");
  const nextAt = at + 1 < speed.tiers.length ? at + 1 : -1;
  const name = (index: number) =>
    index < 0 ? t("picker.tierStandard") : index === 0 ? t("picker.tierFast") : t("picker.tierUltrafast");
  const label = t("composer.speedLabel", { tier: name(at) });
  return createPortal(
    <button
      type="button"
      className="acpmux-fast"
      data-tier={at < 0 ? "off" : at === 0 ? "fast" : "ultrafast"}
      aria-pressed={at >= 0}
      aria-label={label}
      {...tooltipProps(t("composer.speedTooltip", { tier: name(at), next: name(nextAt) }), undefined)}
      // Keep focus and the caret in the prompt, as the mic does; Tab still reaches it.
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => speed.onPick(nextAt < 0 ? speed.off : speed.tiers[nextAt]!)}
    >
      <BoltIcon filled={at > 0} />
    </button>,
    slot,
  );
}

function BoltIcon({ filled }: { filled: boolean }) {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill={filled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M9.2 1.5 3.6 9h4.1l-1 5.5L12.4 7H8.3Z" />
    </svg>
  );
}
