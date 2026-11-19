// The composer's cache chip beside Send (cacheCompactChipModel.ts): "Compact · 312K" once a big
// Claude chat's prompt cache has expired and acpmux will compact before the next prompt; a click
// flips it to "Keep" (send without compacting) and back. Built from the composer's own chip look
// (.acpmux-picker-button) and tokens; cacheCompactChip.css only quiets it.
import "./cacheCompactChip.css";

import { useState } from "react";
import { useCacheTimeLeft } from "../contextCardModel";
import { useT } from "../i18n";
import {
  cacheCompactChipShown,
  cacheCompactMeta,
  toggleCacheCompact,
  type CacheCompactChoice,
} from "./cacheCompactChipModel";

export type CacheCompactChipUsage = { used: number; compactOnReturn?: boolean; cacheExpiresAt?: number } | undefined;

export type CacheCompactChipControl = {
  shown: boolean;
  choice: CacheCompactChoice;
  /// The context's tokens, for the chip's label.
  used: number;
  toggle(): void;
  /// What the next send carries as `_meta.acpmux.cacheCompact` (undefined: no chip, nothing added).
  meta: CacheCompactChoice | undefined;
  /// A send went: the next one starts at Compact again.
  sent(): void;
};

/// The chip's state for the composer. It ticks to the cache's expiry (useCacheTimeLeft), so it
/// appears the moment the cache lapses, without another usage report.
export function useCacheCompactChip({
  usage,
  idle,
  hasText,
  now,
}: {
  usage: CacheCompactChipUsage;
  idle: boolean;
  hasText: boolean;
  /// The clock (the gallery and tests pin it).
  now?: () => number;
}): CacheCompactChipControl {
  const [choice, setChoice] = useState<CacheCompactChoice>("compact");
  const left = useCacheTimeLeft(usage?.compactOnReturn ? usage.cacheExpiresAt : undefined, now);
  const shown = cacheCompactChipShown({
    compactOnReturn: usage?.compactOnReturn,
    cacheExpiresAt: usage?.cacheExpiresAt,
    expired: left !== undefined && left <= 0,
    idle,
    hasText,
  });
  return {
    shown,
    choice,
    used: usage?.used ?? 0,
    toggle: () => setChoice(toggleCacheCompact),
    meta: cacheCompactMeta(shown, choice),
    sent: () => setChoice("compact"),
  };
}

export function CacheCompactChip({ control }: { control: CacheCompactChipControl }) {
  const t = useT();
  if (!control.shown) return null;
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 0 }).format(
    control.used,
  );
  const keep = control.choice === "keep";
  const tip = t(keep ? "composer.cacheKeepTooltip" : "composer.cacheCompactTooltip");
  return (
    <button
      type="button"
      className="acpmux-picker-button acpmux-cache-compact"
      data-choice={control.choice}
      title={tip}
      onClick={control.toggle}
    >
      <span>{keep ? t("composer.cacheKeep") : t("composer.cacheCompact", { tokens })}</span>
    </button>
  );
}
