import React, { useEffect, useId, useRef, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { t } from "./i18n";

/// The effort chip and its popover (reference prototype model-menu.png): the effort's name as a
/// title, the model under it, and a stepped slider with one stop per level the agent offers.
/// The slider is a native range input (arrow keys, Home and End step it), drawn as Codex's
/// track (a click on the track jumps to the nearest stop). Picking sends chat.effort through `onPick`.
export function EffortPicker({
  efforts,
  current,
  model,
  onPick,
  chevron,
}: {
  efforts: Choice[];
  current?: string;
  model?: string;
  onPick(value: string): void;
  chevron?: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLSpanElement>(null);
  const range = useRef<HTMLInputElement>(null);
  const id = useId();
  const level = Math.max(
    0,
    efforts.findIndex((choice) => choice.id === current),
  );
  const name = efforts[level]?.name ?? t("effort.title");
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    range.current?.focus();
    return () => {
      document.removeEventListener("pointerdown", away);
      window.removeEventListener("blur", blur);
    };
  }, [open]);
  const pick = (index: number) => {
    const choice = efforts[index];
    if (choice && choice.id !== current) onPick(choice.id);
  };
  const share = efforts.length > 1 ? level / (efforts.length - 1) : 0;
  return (
    <span ref={root} className="acpmux-picker acpmux-effort">
      <button
        type="button"
        className="acpmux-picker-button"
        aria-label={t("effort.title")}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen(!open)}
      >
        <span>{name}</span>
        {chevron}
      </button>
      {open && (
        <div
          className="acpmux-menu acpmux-menu-end acpmux-effort-pop"
          id={id}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="dialog"
          aria-label={t("effort.title")}
        >
          <div className="acpmux-effort-title">{name}</div>
          {model && <div className="acpmux-effort-model">{model}</div>}
          <div className="acpmux-effort-track" style={{ "--acpmux-effort": share } as React.CSSProperties}>
            <span className="acpmux-effort-fill" />
            {efforts.map((choice, index) =>
              index === level ? null : (
                <span
                  key={choice.id}
                  className="acpmux-effort-stop"
                  aria-hidden="true"
                  style={
                    { "--acpmux-stop": efforts.length > 1 ? index / (efforts.length - 1) : 0 } as React.CSSProperties
                  }
                />
              ),
            )}
            <span className="acpmux-effort-thumb" />
            <input
              ref={range}
              className="acpmux-effort-range"
              type="range"
              min={0}
              max={Math.max(efforts.length - 1, 0)}
              step={1}
              value={level}
              aria-label={t("effort.title")}
              aria-valuetext={name}
              onChange={(event) => pick(Number(event.target.value))}
              onKeyDown={(event) => {
                if (event.key !== "Escape") return;
                event.preventDefault();
                event.stopPropagation();
                setOpen(false);
                root.current?.querySelector("button")?.focus();
              }}
            />
          </div>
        </div>
      )}
    </span>
  );
}
