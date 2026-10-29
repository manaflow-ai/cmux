import React, { useContext, useEffect, useRef, useState } from "react";
import { usePopupHost } from "../../ui/UiProvider";
import { Menu, MenuButton, MenuGroup, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { type ConfigOption, optionValueName } from "./agentOptions";
import { ChevronIcon, unrestricted } from "./ComposerPickers";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import { useComposerPopup, popupChoice, popupSection, popupIdentity } from "./nativeComposerPopup";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";

/** Harness option menu with scoped choice IDs and browser rendering when native transport is absent. */
export function AgentOptionsMenu({
  options,
  managed = false,
  managedReason,
  onPick,
}: {
  options: ConfigOption[];
  managed?: boolean;
  managedReason?: string;
  onPick(configId: string, value: string): void;
}) {
  const blocked = (value: string) => managed && unrestricted(value);
  const t = useT();
  const native = usePopupHost()?.native;
  const newTab = useContext(OnNewTab);
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const label = t("picker.options");
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  const only = options.length === 1 ? options[0] : undefined;
  const face = only ? `${only.name ?? only.id}: ${optionValueName(only) ?? ""}` : label;
  const tooltip = [
    ...options.map((option) => `${option.name ?? option.id}: ${optionValueName(option) ?? ""}`),
    t("picker.optionsHelp"),
  ].join("\n");
  const choiceById = new Map<string, { configId: string; value: string }>();
  const rows: NativePopupRow[] = options.flatMap((option) =>
    popupSection(
      popupIdentity("option-heading", option.id),
      option.name ?? option.id,
      option.options.map((choice) => {
        const id = popupIdentity("option", option.id, choice.value);
        choiceById.set(id, { configId: option.id, value: choice.value });
        return popupChoice(id, choice.name ?? choice.value, {
          description: blocked(choice.value) ? managedReason : choice.description,
          disabled: blocked(choice.value),
          disabledReason: blocked(choice.value) ? managedReason : undefined,
          checked: choice.value === option.currentValue,
        });
      }),
    ),
  );
  const pickChoice = (configId: string, value: string) => {
    const option = options.find((item) => item.id === configId);
    if (blocked(value) || !option || !option.options.some((choice) => choice.value === value)) return;
    setOpen(false);
    if (option.currentValue !== value) onPick(configId, value);
  };
  useComposerPopup({
    open: Boolean(native) && open,
    anchor: () => trigger.current,
    model: {
      side: newTab ? "bottom" : "top",
      align: "start",
      width: 300,
      title: label,
      rows,
    },
    onEvent: (event: NativePopupEvent) => {
      if (event.type !== "pick" || !event.id) return;
      const choice = choiceById.get(event.id);
      if (choice) pickChoice(choice.configId, choice.value);
    },
    onDismiss: () => setOpen(false),
  });
  if (options.length === 0) return null;
  if (!native)
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
                    pickChoice(option.id, value);
                  }}
                >
                  {option.options.map((choice) => (
                    <MenuRadioItem
                      key={choice.value}
                      value={choice.value}
                      disabled={blocked(choice.value)}
                      closeOnClick
                    >
                      <span className="acpmux-menu-text">
                        <span className="acpmux-menu-label">{choice.name ?? choice.value}</span>
                        {blocked(choice.value) && managedReason ? (
                          <span className="acpmux-menu-description">{managedReason}</span>
                        ) : choice.description ? (
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

  return (
    <span className="acpmux-picker acpmux-options" data-fit-title={face} data-fit-title-unit="options">
      <button
        ref={trigger}
        type="button"
        className="acpmux-picker-button acpmux-options-trigger"
        aria-label={label}
        title={tooltip}
        aria-haspopup="menu"
        aria-expanded={open}
        data-menu="options"
        onClick={() => setOpen((was) => !was)}
      >
        <span className="acpmux-options-text">{face}</span>
        <ChevronIcon />
      </button>
    </span>
  );
}
