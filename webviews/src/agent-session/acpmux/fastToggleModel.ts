import { createContext, useContext, useEffect, useRef } from "react";

/// Codex's speed toggle (Leo 2026-10-21: "REMOVE it for Claude, where Fast mode lives inside the
/// menu. KEEP it for Codex"): a lightning bolt in the box's trailing cluster, just left of the mic,
/// as #20964 drew it. Claude Code's Fast mode is a row of the model button's menu instead
/// (QuickModelMenu.tsx), so a Claude chat draws no bolt. The chips own the session's speed option,
/// so they hand it up through this setter and the composer draws the bolt before the mic
/// (Composer.tsx). A composer without the setter draws none.
export const SpeedToggleHost = createContext<((speed: SpeedTiers | undefined) => void) | null>(null);

/// The session's speed option (Codex's service tier): its off value and the faster tiers it offers,
/// in the agent's order (Fast, then Ultrafast where one is offered).
export type SpeedTiers = {
  current?: string;
  off: string;
  tiers: string[];
  names?: Record<string, string>;
  /// Sends the pick as the menu's rows do (chat.effort, configId=value).
  onPick(value: string): void;
};

/// Hands `speed` to the composer that draws the bolt (SpeedToggleHost), again only when what it
/// shows changes; the latest pick handler is always the one a click runs. Returns whether a
/// composer draws the bolt here: without one, the speed stays a row of the model button's menu.
export function useSpeedToggle(speed: SpeedTiers | undefined): boolean {
  const publish = useContext(SpeedToggleHost);
  const pick = useRef(speed?.onPick);
  pick.current = speed?.onPick;
  const offered = speed !== undefined;
  const current = speed?.current;
  const off = speed?.off ?? "";
  const tiers = speed?.tiers.join("\u0000") ?? "";
  const names = JSON.stringify(speed?.names);
  useEffect(() => {
    if (!publish) return;
    publish(
      offered
        ? {
            current,
            off,
            tiers: tiers.split("\u0000"),
            names: names ? JSON.parse(names) : undefined,
            onPick: (value) => pick.current?.(value),
          }
        : undefined,
    );
  }, [publish, offered, current, off, tiers, names]);
  useEffect(() => (publish ? () => publish(undefined) : undefined), [publish]);
  return publish !== null;
}
