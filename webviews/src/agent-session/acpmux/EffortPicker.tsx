import React, { useEffect, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
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
/// with one checked row per level the model offers, a Default badge on the model's own level and
/// a line under a level that needs one (Ultracode); then the speed section when the agent has one.
/// The chip names the level, plus "Fast" while fast mode is on. The menu is the shared popup
/// layer's opaque surface (ui/Menu), so nothing shows through it. Picking sends chat.effort
/// through `onPick` (and the speed section's own `onPick`).
export function EffortPicker({
  label,
  efforts,
  current,
  onPick,
  speed,
  chevron,
}: {
  /// The stable name automation opens it by (`openPicker`), whatever the UI language.
  label: string;
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  speed?: SpeedSection;
  chevron?: React.ReactNode;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const selected = efforts.find((choice) => choice.id === current) ?? efforts[0];
  const level = !selected || isDefaultChoice(selected) ? t("picker.reasoning") : selected.name;
  const fast = speed !== undefined && speed.current === speed.on;
  // Automation opens the menu by its label as a click does (see pickerOpeners.ts).
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  const row = (choice: Choice) => (
    <MenuRadioItem key={choice.id} value={choice.id} className="acpmux-effort-item">
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-1.5">
          <span className="acpmux-menu-label">{choice.name}</span>
          {choice.hint && (
            <span className="rounded border-[0.5px] border-edge px-1 text-[11px] leading-4 text-dim">
              {choice.hint}
            </span>
          )}
        </span>
        {choice.description && <span className="text-[12px] leading-4 text-dim">{choice.description}</span>}
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
          <MenuGroup label={t("picker.reasoning")}>
            <MenuRadioGroup
              value={selected?.id ?? ""}
              onValueChange={(next) => {
                onPick(next);
                setOpen(false);
              }}
            >
              {efforts.map(row)}
            </MenuRadioGroup>
          </MenuGroup>
          {speed && (
            <>
              <MenuSeparator />
              <MenuGroup label={speed.title}>
                <MenuRadioGroup
                  value={speed.current ?? ""}
                  onValueChange={(next) => {
                    speed.onPick(next);
                    setOpen(false);
                  }}
                >
                  {speed.choices.map(row)}
                </MenuRadioGroup>
              </MenuGroup>
            </>
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}
