import React, { useContext, useEffect, useState } from "react";
import { Menu, MenuButton, MenuGroup, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { type ConfigOption, optionValueName } from "./agentOptions";
import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";

/// The composer's Options chip: every config option the harness advertises that has no chip of
/// its own (`extraConfigOptions`), each a group of its choices. One option names itself on the
/// chip; more show as Options. A pick goes through the same `session/set_config_option` path as
/// the effort chip, and the session's report moves the check.
export function AgentOptionsMenu({
  options,
  onPick,
}: {
  options: ConfigOption[];
  onPick(configId: string, value: string): void;
}) {
  const t = useT();
  // On New Tab the menu opens down (newTabComposer.ts).
  const newTab = useContext(OnNewTab);
  const [open, setOpen] = useState(false);
  const label = t("picker.options");
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  if (options.length === 0) return null;
  const only = options.length === 1 ? options[0] : undefined;
  const face = only ? `${only.name ?? only.id}: ${optionValueName(only) ?? ""}` : label;
  const tooltip = [
    ...options.map((option) => `${option.name ?? option.id}: ${optionValueName(option) ?? ""}`),
    t("picker.optionsHelp"),
  ].join("\n");
  return (
    <span className="acpmux-picker acpmux-options" data-fit-title={face} data-fit-title-unit="options">
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton
          className="acpmux-picker-button acpmux-options-trigger"
          label={label}
          /* tooltip-allow: the chip names one option or reads Options; the tooltip lists every current choice */
          title={tooltip}
          aria-haspopup="menu"
          data-menu="options"
        >
          <span className="acpmux-options-text">{face}</span>
          <ChevronIcon />
        </MenuButton>
        <MenuPopup side={newTab ? "bottom" : "top"} align="start" className="acpmux-access-menu acpmux-options-menu">
          {options.map((option) => (
            <MenuGroup key={option.id} label={option.name ?? option.id}>
              <MenuRadioGroup
                value={option.currentValue ?? ""}
                onValueChange={(value) => {
                  setOpen(false);
                  if (value !== option.currentValue) onPick(option.id, value);
                }}
              >
                {option.options.map((choice) => (
                  <MenuRadioItem key={choice.value} value={choice.value} closeOnClick>
                    <span className="acpmux-menu-text">
                      <span className="acpmux-menu-label">{choice.name ?? choice.value}</span>
                      {choice.description ? (
                        <span className="acpmux-menu-description">{choice.description}</span>
                      ) : null}
                    </span>
                  </MenuRadioItem>
                ))}
              </MenuRadioGroup>
            </MenuGroup>
          ))}
        </MenuPopup>
      </Menu>
    </span>
  );
}
