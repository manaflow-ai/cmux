import React, { createContext, useContext, useEffect, useRef } from "react";
import { useT } from "./i18n";
import { tooltipProps } from "./shortcuts";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";

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

/// The bolt: a plain outline glyph in muted ink while off, in the theme accent while a tier runs. No
/// disc, no fill at rest; hover draws the row's soft pill (composerLocation.css `.acpmux-fast`). A
/// click steps to the next offered tier, and from the last one back to off; with one tier it is
/// on/off.
export function FastToggle({ speed, inline = false }: { speed: SpeedTiers; inline?: boolean }) {
  const t = useT();
  if (speed.tiers.length === 0) return null;
  const at = speed.tiers.indexOf(speed.current ?? "");
  const nextAt = at + 1 < speed.tiers.length ? at + 1 : -1;
  const name = (index: number) => {
    const value = speed.tiers[index] ?? "";
    if (index < 0) return t("picker.tierStandard");
    if (/^(priority|fast|on|true|enabled)$/i.test(value)) return t("picker.tierFast");
    if (/^ultra[-_ ]?fast$/i.test(value)) return t("picker.tierUltrafast");
    return speed.names?.[value] ?? value;
  };
  const label = t("composer.speedLabel", { tier: name(at) });
  return (
    <span className="acpmux-speed">
      {inline ? (
        <button
          type="button"
          className="acpmux-fast"
          data-tier={at < 0 ? "off" : at === 0 ? "fast" : "ultrafast"}
          aria-pressed={at >= 0}
          aria-label={label}
          {...tooltipProps(t("composer.speedTooltip", { tier: name(at), next: name(nextAt) }), undefined)}
          // The inline glyph lives inside the model picker trigger. Stop the pointer gesture
          // before the parent trigger sees it, so choosing Fast does not also open the picker.
          onPointerDown={(event) => {
            event.preventDefault();
            event.stopPropagation();
          }}
          onClick={(event) => {
            event.stopPropagation();
            speed.onPick(nextAt < 0 ? speed.off : speed.tiers[nextAt]!);
          }}
          onKeyDown={(event) => {
            if (event.key !== "Enter" && event.key !== " ") return;
            event.preventDefault();
            event.stopPropagation();
            speed.onPick(nextAt < 0 ? speed.off : speed.tiers[nextAt]!);
          }}
        >
          <BoltIcon />
        </button>
      ) : (
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
          <BoltIcon />
          <span>{name(at < 0 ? 0 : at)}</span>
        </button>
      )}
      {!inline && (
        <Menu>
          <MenuButton className="acpmux-speed-choices" label={label} data-menu="Speed">
            ⌄
          </MenuButton>
          <MenuPopup className="acpmux-menu" label={label}>
            <MenuRadioGroup value={speed.current ?? speed.off} onValueChange={speed.onPick}>
              {[speed.off, ...speed.tiers].map((value, index) => (
                <MenuRadioItem key={value} value={value} closeOnClick>
                  {name(index - 1)}
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          </MenuPopup>
        </Menu>
      )}
    </span>
  );
}

function BoltIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
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
