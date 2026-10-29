import React, { useContext, useEffect, useRef, useState } from "react";
import { type ConfigOption, optionValueName } from "./agentOptions";
import { ChevronIcon, unrestricted } from "./ComposerPickers";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import { useComposerPopup, popupChoice, popupSection, popupIdentity } from "./nativeComposerPopup";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";

/** Native-only menu for harness config options. Choice IDs remain scoped to their config option. */
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
  useComposerPopup({
    open,
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
      const option = choice && options.find((item) => item.id === choice.configId);
      if (choice && !blocked(choice.value) && option && option.currentValue !== choice.value)
        onPick(choice.configId, choice.value);
    },
    onDismiss: () => setOpen(false),
  });
  if (options.length === 0) return null;
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
