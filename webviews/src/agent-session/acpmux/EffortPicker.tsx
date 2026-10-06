import React, { useEffect, useId, useRef, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
import { useT } from "./i18n";
import { useEscapeCloses } from "./menuEscape";
import { registerPicker } from "./pickerOpeners";
import { useUiAnchor } from "../../ui/anchor";

/// The effort chip and its popover (reference prototype model-menu.png): the effort's name as a
/// title, the model under it (a default level says "Reasoning" on the chip), and a stepped slider with one stop per level the agent offers.
/// The slider is EffortTrack. Picking sends chat.effort through `onPick`.
export function EffortPicker({
  label,
  efforts,
  current,
  model,
  onPick,
  chevron,
}: {
  /// The stable name automation opens it by (`openPicker`), whatever the UI language.
  label: string;
  efforts: Choice[];
  current?: string;
  model?: string;
  onPick(value: string): void;
  chevron?: React.ReactNode;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const id = useId();
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
  const level = Math.max(
    0,
    efforts.findIndex((choice) => choice.id === current),
  );
  const name = efforts[level]?.name ?? t("effort.title");
  // The agent's default level names no level: the chip says "Reasoning" beside the model chip
  // rather than a second "Default"; the popover title says "Default".
  const chip = efforts[level] && isDefaultChoice(efforts[level]) ? t("picker.reasoning") : name;
  // Automation opens the popover by its label as a click does (see pickerOpeners.ts).
  // Already open, it only puts the focus back on the slider.
  useEffect(
    () =>
      registerPicker(label, () => {
        const range = root.current?.querySelector<HTMLInputElement>(".acpmux-effort-range");
        if (range) {
          range.focus();
          return;
        }
        if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
        setOpen(true);
      }),
    [label],
  );
  const close = () => {
    setOpen(false);
    trigger.current?.focus();
  };
  useEscapeCloses(open, close);
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away);
      window.removeEventListener("blur", blur);
    };
  }, [open]);
  return (
    <span ref={root} className="acpmux-picker acpmux-effort" style={{ position: "relative" }}>
      <button
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        data-menu={label}
        aria-label={t("effort.title")}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen(!open)}
      >
        <span>{chip}</span>
        {chevron}
      </button>
      {open && (
        <div
          ref={menu}
          className="acpmux-menu acpmux-menu-end acpmux-effort-pop"
          style={menuStyle}
          id={id}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="dialog"
          aria-label={t("effort.title")}
        >
          <div className="acpmux-effort-title">{name}</div>
          {model && <div className="acpmux-effort-model">{model}</div>}
          <EffortTrack efforts={efforts} current={current} onPick={onPick} autoFocus onEscape={close} />
        </div>
      )}
    </span>
  );
}
