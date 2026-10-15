import React, { useEffect, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { Menu, MenuButton, MenuGroup, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";

/// A second choice in the reasoning menu: Claude Code's Fast Mode (On/Off) or Codex's Service
/// Tier (Standard/Fast). `on` is the choice that makes the chip say "Fast".
export type SpeedSection = {
  title: string;
  choices: Choice[];
  current?: string;
  on: string;
  onPick(value: string): void;
};

/// The reasoning chip and its menu (Lawrence 2026-10-09, MonoCode's picker): a Reasoning section
/// with one checked row per level the model offers and a line under a level that needs one
/// (Ultracode); then the speed section when the agent has one.
/// The chip names the level, plus "Fast" while fast mode is on. The menu is the shared popup
/// layer's opaque surface (ui/Menu), so nothing shows through it. Picking sends chat.effort
/// through `onPick` (and the speed section's own `onPick`).
/// With `slider` (`agentPane.reasoningSlider`, opt-in) the Reasoning section is the model picker's
/// stepped slider (EffortTrack) instead of the rows, when the model offers two or more levels. The
/// slider picks as it moves and keeps the menu open; Escape closes it back to the chip.
export function EffortPicker({
  label,
  efforts,
  current,
  onPick,
  speed,
  chevron,
  slider = false,
}: {
  /// The stable name automation opens it by (`openPicker`), whatever the UI language.
  label: string;
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  speed?: SpeedSection;
  chevron?: React.ReactNode;
  /// Draw the Reasoning section as a slider (the person's opt-in); the list is the default.
  slider?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  // The agent's implicit level is represented by the chip, not a second "Default" row. Keep the
  // real levels in the menu so the first arrow lands on an actionable choice.
  const visibleEfforts = efforts.filter((choice) => !isDefaultChoice(choice));
  const selected = efforts.find((choice) => choice.id === current) ?? efforts[0];
  const selectedVisible = visibleEfforts.find((choice) => choice.id === current);
  const level = !selected || isDefaultChoice(selected) ? t("picker.reasoning") : selected.name;
  const fast = speed !== undefined && speed.current === speed.on;
  // One level is nothing to slide between: the list shows it as a single checked row.
  const sliding = slider && visibleEfforts.length > 1;
  const recommended = visibleEfforts.find((choice) => choice.recommended);
  // The level the thumb shows: the picked one, else (the agent's own default) the recommended one.
  const shown = selectedVisible ?? recommended ?? visibleEfforts[0];
  // Automation opens the menu by its label as a click does (see pickerOpeners.ts).
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  // Base UI initially focuses the popup while it measures its anchor. Move focus to the selected
  // reasoning row on the next frame, after the popup is mounted and positioned, so ArrowDown starts
  // from the visible choice for both a click and automation opening by label.
  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      const range = document.querySelector<HTMLElement>(".acpmux-effort-menu .acpmux-effort-range");
      if (range) {
        range.focus({ preventScroll: true });
        return;
      }
      const reasoningGroup = document.querySelector<HTMLElement>('.acpmux-effort-menu [role="group"]');
      const selectedReasoning =
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]') ??
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"]');
      selectedReasoning?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [open]);
  const row = (choice: Choice) => (
    <MenuRadioItem key={choice.id} value={choice.id} className="acpmux-effort-item">
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-1.5">
          <span className="acpmux-menu-label">{choice.name}</span>
          {choice.hint && (
            <span className="rounded border-[0.5px] border-edge px-1 text-caption text-dim">{choice.hint}</span>
          )}
        </span>
        {choice.description && <span className="text-detail text-dim">{choice.description}</span>}
      </span>
    </MenuRadioItem>
  );
  const speedRows = speed && (
    <MenuRadioGroup
      value={speed.current ?? ""}
      onValueChange={(next) => {
        speed.onPick(next);
        setOpen(false);
      }}
    >
      {speed.choices.map(row)}
    </MenuRadioGroup>
  );
  return (
    <span className="acpmux-picker acpmux-effort">
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-picker-button" label={t("effort.title")} data-menu={label} aria-haspopup="menu">
          <span>{fast ? `${level} ${t("picker.chipFast")}` : level}</span>
          {chevron}
        </MenuButton>
        <MenuPopup side="top" align="start" className="acpmux-effort-menu">
          {sliding && (
            <ReasoningSlider
              title={t("picker.reasoning")}
              efforts={visibleEfforts}
              current={selectedVisible?.id}
              shown={shown}
              fallback={recommended?.id}
              onPick={onPick}
              onClose={() => setOpen(false)}
            />
          )}
          {!sliding && visibleEfforts.length > 0 && (
            <MenuGroup label={t("picker.reasoning")}>
              <MenuRadioGroup
                value={selectedVisible?.id ?? ""}
                onValueChange={(next) => {
                  onPick(next);
                  setOpen(false);
                }}
              >
                {visibleEfforts.map(row)}
              </MenuRadioGroup>
            </MenuGroup>
          )}
          {speed && (
            <>
              <MenuSeparator />
              <MenuGroup label={speed.title}>
                {sliding ? (
                  // Up from the first speed row climbs back to the slider, which is not a menu row.
                  <div
                    className="contents"
                    // ui-allow: the menu's own row navigation cannot reach a non-row control.
                    onKeyDownCapture={toSliderFromFirstRow}
                  >
                    {speedRows}
                  </div>
                ) : (
                  speedRows
                )}
              </MenuGroup>
            </>
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// Keys the slider steps by itself, so the menu's own row navigation and typeahead never see them.
const SLIDER_KEYS = new Set(["ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"]);

/// The Reasoning section as a slider: its title and the level it sits on, then the track. Left,
/// Right, Home and End step it; Up and Down step it too unless the speed rows follow, where Down
/// moves to them (and Up from the first climbs back). Escape closes the menu back to the chip.
function ReasoningSlider({
  title,
  efforts,
  current,
  shown,
  fallback,
  onPick,
  onClose,
}: {
  title: string;
  efforts: Choice[];
  current?: string;
  shown?: Choice;
  fallback?: string;
  onPick(value: string): void;
  onClose(): void;
}) {
  const onRangeKey = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (SLIDER_KEYS.has(event.key)) {
      event.stopPropagation();
      return;
    }
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.stopPropagation();
    const below = event.currentTarget
      .closest(".acpmux-effort-menu")
      ?.querySelector<HTMLElement>('[role="menuitemradio"]');
    if (!below) return;
    // With rows below, vertical arrows travel the menu as they do in any menu.
    event.preventDefault();
    if (event.key === "ArrowDown") below.focus();
  };
  return (
    <div className="acpmux-effort-slider">
      <div className="acpmux-effort-slider-head">
        <span className="ui-menu-group-label">{title}</span>
        <span className="acpmux-effort-slider-level" title={shown?.description}>
          {shown?.name}
        </span>
      </div>
      <EffortTrack
        efforts={efforts}
        current={current}
        fallback={fallback}
        onPick={onPick}
        onEscape={onClose}
        onRangeKey={onRangeKey}
      />
    </div>
  );
}

/// ArrowUp on the first speed row focuses the slider above it instead of wrapping to the last row.
function toSliderFromFirstRow(event: React.KeyboardEvent<HTMLElement>) {
  if (event.key !== "ArrowUp") return;
  const menu = (event.target as HTMLElement).closest(".acpmux-effort-menu");
  const first = menu?.querySelector<HTMLElement>('[role="menuitemradio"]');
  if (!menu || event.target !== first) return;
  event.preventDefault();
  event.stopPropagation();
  menu.querySelector<HTMLElement>(".acpmux-effort-range")?.focus();
}
