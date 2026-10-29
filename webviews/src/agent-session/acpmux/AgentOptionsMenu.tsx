import React, { useContext, useEffect, useRef, useState } from "react";
import { type ConfigOption, optionValueName } from "./agentOptions";
import { ChevronIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import {
  useComposerPopup,
  popupChoice,
  popupSection,
} from "./nativeComposerPopup";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";

/** Native-only menu for harness config options. Choice IDs remain scoped to their config option. */
export function AgentOptionsMenu({
  options,
  onPick,
}: {
  options: ConfigOption[];
  onPick(configId: string, value: string): void;
}) {
  const t = useT();
  const newTab = useContext(OnNewTab);
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const label = t("picker.options");
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  const only = options.length === 1 ? options[0] : undefined;
  const face = only
    ? `${only.name ?? only.id}: ${optionValueName(only) ?? ""}`
    : label;
  const tooltip = [
    ...options.map(
      (option) =>
        `${option.name ?? option.id}: ${optionValueName(option) ?? ""}`,
    ),
    t("picker.optionsHelp"),
  ].join("\n");
  const rows: NativePopupRow[] = options.map((option) =>
    popupSection(
      `option:${option.id}`,
      option.name ?? option.id,
      option.options.map((choice) =>
        popupChoice(
          `${option.id}\u0000${choice.value}`,
          choice.name ?? choice.value,
          {
            description: choice.description,
            checked: choice.value === option.currentValue,
          },
        ),
      ),
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
      const separator = event.id.indexOf("\u0000");
      if (separator < 0) return;
      const configId = event.id.slice(0, separator);
      const value = event.id.slice(separator + 1);
      const option = options.find((item) => item.id === configId);
      if (option && option.currentValue !== value) onPick(configId, value);
    },
    onDismiss: () => setOpen(false),
  });
  if (options.length === 0) return null;
  return (
    <span
      className="acpmux-picker acpmux-options"
      data-fit-title={face}
      data-fit-title-unit="options"
    >
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
