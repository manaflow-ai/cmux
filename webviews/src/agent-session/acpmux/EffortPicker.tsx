import React, { useEffect, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { Menu, MenuButton, MenuGroup, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";

/// A switch section in the reasoning menu: Claude Code's Fast Mode (On/Off) or Codex's Service
/// Tier (Standard/Fast), and Claude Code's Ultracode. `on` is the choice the chip names.
export type SpeedSection = {
  title: string;
  choices: Choice[];
  current?: string;
  on: string;
  onPick(value: string): void;
};

/// The reasoning chip and its menu (Lawrence 2026-10-09, MonoCode's picker): a Reasoning section
/// with one checked row per level the model offers; then Ultracode and the speed section when the
/// agent has them. The agent's own level ("default", `defaulted`) checks the level it resolves to,
/// with a Default hint, and the chip names that level; unresolved, it says Reasoning, never the
/// first level. The chip says Ultracode while that is on, plus "Fast" while fast mode is on.
/// The menu is the shared popup layer's opaque surface (ui/Menu), so nothing shows through it.
/// Picking sends chat.effort through `onPick` (and each section's own `onPick`).
export function EffortPicker({
  label,
  efforts,
  current,
  onPick,
  defaulted = false,
  ultracode,
  speed,
  chevron,
}: {
  /// The stable name automation opens it by (`openPicker`), whatever the UI language.
  label: string;
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  /// The agent runs its own level; `current` is the level that resolves to.
  defaulted?: boolean;
  ultracode?: SpeedSection;
  speed?: SpeedSection;
  chevron?: React.ReactNode;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  // The agent's implicit level is represented by the chip, not a second "Default" row. Keep the
  // real levels in the menu so the first arrow lands on an actionable choice.
  const visibleEfforts = efforts.filter((choice) => !isDefaultChoice(choice));
  const selectedVisible = visibleEfforts.find((choice) => choice.id === current);
  const level =
    ultracode && ultracode.current === ultracode.on
      ? ultracode.title
      : (selectedVisible?.name ?? t("picker.reasoning"));
  const fast = speed !== undefined && speed.current === speed.on;
  // Automation opens the menu by its label as a click does (see pickerOpeners.ts).
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  // Base UI initially focuses the popup while it measures its anchor. Move focus to the selected
  // reasoning row on the next frame, after the popup is mounted and positioned, so ArrowDown starts
  // from the visible choice for both a click and automation opening by label.
  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      const reasoningGroup = document.querySelector<HTMLElement>('.acpmux-effort-menu [role="group"]');
      const selectedReasoning =
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]') ??
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"]');
      selectedReasoning?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [open]);
  const levelRow = (choice: Choice) =>
    row(defaulted && choice.id === selectedVisible?.id ? { ...choice, hint: t("picker.default") } : choice);
  // One line per row, as a native menu: the check in its own leading gutter (empty when the row is
  // not chosen, so every label starts at the same x), the label, a hint, and a short note (Ultracode)
  // in secondary text on the same line, its full text in the tooltip when the menu clips it.
  const row = (choice: Choice) => (
    <MenuRadioItem key={choice.id} value={choice.id} className="acpmux-effort-item">
      <span className="acpmux-effort-text">
        <span className="acpmux-menu-label">{choice.name}</span>
        {choice.hint && (
          <span className="acpmux-effort-hint rounded border-[length:var(--cmux-hairline,0.5px)] border-edge px-1 text-caption text-dim">
            {choice.hint}
          </span>
        )}
        {choice.description && (
          // tooltip-allow: the note is cut with an ellipsis when the menu is narrow; the tooltip is its whole text
          <span className="acpmux-effort-detail" title={choice.description}>
            {choice.description}
          </span>
        )}
      </span>
    </MenuRadioItem>
  );
  return (
    <span className="acpmux-picker acpmux-effort">
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-picker-button" label={t("effort.title")} data-menu={label} aria-haspopup="menu">
          <span>{fast ? `${level} ${t("picker.chipFast")}` : level}</span>
          {chevron}
        </MenuButton>
        <MenuPopup side="top" align="start" className="acpmux-effort-menu">
          {visibleEfforts.length > 0 && (
            <MenuGroup label={t("picker.reasoning")}>
              <MenuRadioGroup
                value={selectedVisible?.id ?? ""}
                onValueChange={(next) => {
                  onPick(next);
                  setOpen(false);
                }}
              >
                {visibleEfforts.map(levelRow)}
              </MenuRadioGroup>
            </MenuGroup>
          )}
          {[ultracode, speed].map(
            (section) =>
              section && (
                <React.Fragment key={section.title}>
                  <MenuSeparator />
                  <MenuGroup label={section.title}>
                    <MenuRadioGroup
                      value={section.current ?? ""}
                      onValueChange={(next) => {
                        section.onPick(next);
                        setOpen(false);
                      }}
                    >
                      {section.choices.map(row)}
                    </MenuRadioGroup>
                  </MenuGroup>
                </React.Fragment>
              ),
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}
