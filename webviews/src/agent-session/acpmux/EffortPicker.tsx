import React, { useEffect, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";

/// The reasoning chip and its menu: one checked row per level the model offers, nothing else.
/// The agent's default level names no level, so the chip says "Reasoning" rather than "Default"
/// next to the model chip. Picking sends chat.effort through `onPick`.
export function EffortPicker({
  label,
  efforts,
  current,
  onPick,
  chevron,
}: {
  /// The stable name automation opens it by (`openPicker`), whatever the UI language.
  label: string;
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  chevron?: React.ReactNode;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const selected = efforts.find((choice) => choice.id === current) ?? efforts[0];
  const chip = !selected || isDefaultChoice(selected) ? t("picker.reasoning") : selected.name;
  // Automation opens the menu by its label as a click does (see pickerOpeners.ts).
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  return (
    <span className="acpmux-picker acpmux-effort">
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-picker-button" label={t("effort.title")} data-menu={label} aria-haspopup="menu">
          <span>{chip}</span>
          {chevron}
        </MenuButton>
        <MenuPopup side="top" align="start" className="acpmux-effort-menu">
          <MenuRadioGroup
            value={selected?.id ?? ""}
            onValueChange={(next) => {
              onPick(next);
              setOpen(false);
            }}
          >
            {efforts.map((choice) => (
              <MenuRadioItem key={choice.id} value={choice.id} className="acpmux-effort-item">
                <span className="acpmux-menu-label">{choice.name}</span>
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}
