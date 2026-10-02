import React, { useEffect, useId, useRef, useState } from "react";
import { registerPicker } from "./pickerOpeners";

// The effort control, after Codex's (codex-atlas-clone reference model-menu): the chip
// opens a popover with the effort's name, the model it applies to (which opens the
// model menu), and a slider with a stop per level. A native range input, so arrows,
// Home and End, and assistive tech work as on any slider.

export type EffortLevel = { id: string; name: string };

export function EffortSlider({
  label,
  levels,
  current,
  modelName,
  chevron,
  onEffort,
  onModel,
}: {
  label: string;
  levels: EffortLevel[];
  current?: string;
  modelName?: string;
  chevron: React.ReactNode;
  onEffort(id: string): void;
  /// Opens the model menu from the popover's model line.
  onModel?(): void;
}) {
  const [open, setOpen] = useState(false);
  const at = Math.max(
    0,
    levels.findIndex((level) => level.id === current),
  );
  // The level under the thumb, by id so a live update to the levels can't shift it; it is
  // sent when the drag or key press ends, not at each step.
  const [pending, setPending] = useState<string | undefined>(undefined);
  const pendingAt = levels.findIndex((level) => level.id === pending);
  const shown = pendingAt >= 0 ? pendingAt : at;
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const slider = useRef<HTMLInputElement>(null);
  const popId = useId();

  const show = () => {
    setPending(undefined);
    setOpen(true);
  };
  const showRef = useRef(show);
  showRef.current = show;
  useEffect(() => registerPicker(label, () => showRef.current()), [label]);

  useEffect(() => {
    if (!open) return;
    slider.current?.focus();
    // Every way out but Escape keeps the level under the thumb, as a key or drag ending would.
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) dismissRef.current();
    };
    const blur = () => dismissRef.current();
    // Escape inside the popover closes it and hands focus back to the chip.
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || !root.current?.contains(event.target as Node)) return;
      event.preventDefault();
      event.stopPropagation();
      cancelRef.current();
    };
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", escape, true);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", escape, true);
      window.removeEventListener("blur", blur);
    };
  }, [open]);

  const commit = () => {
    if (pending === undefined) return;
    setPending(undefined);
    if (pendingAt >= 0 && pending !== current) onEffort(pending);
  };
  const dismiss = () => {
    commit();
    setOpen(false);
  };
  // Escape backs out: the level the thumb was moved to but not yet sent is dropped.
  const cancel = () => {
    setPending(undefined);
    setOpen(false);
    trigger.current?.focus();
  };
  const dismissRef = useRef(dismiss);
  dismissRef.current = dismiss;
  const cancelRef = useRef(cancel);
  cancelRef.current = cancel;

  return (
    <span
      ref={root}
      className="acpmux-picker acpmux-effort"
      onBlur={(event) => {
        if (open && !root.current?.contains(event.relatedTarget as Node | null)) dismiss();
      }}
    >
      <button
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? popId : undefined}
        onClick={() => {
          if (!open) return show();
          dismiss();
          trigger.current?.focus();
        }}
      >
        <span>{levels[at]?.name ?? label}</span>
        {chevron}
      </button>
      {open && (
        <dialog id={popId} className="acpmux-effort-pop" open aria-label={label}>
          <div className="acpmux-effort-name">{levels[shown]?.name}</div>
          {modelName && (
            <button
              type="button"
              className="acpmux-effort-model"
              onClick={() => {
                dismiss();
                onModel?.();
              }}
            >
              {modelName}
              <svg width={10} height={10} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
                <path
                  d="M6.3 3.4 10.6 8l-4.3 4.6"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth={1.6}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </button>
          )}
          <div
            className="acpmux-effort-track"
            // The track fills up to the thumb.
            style={
              {
                "--acpmux-effort-stops": levels.length,
                "--acpmux-effort-fill": levels.length > 1 ? shown / (levels.length - 1) : 0,
              } as React.CSSProperties
            }
          >
            {levels.map((level, index) => (
              <span
                key={level.id}
                className="acpmux-effort-stop"
                aria-hidden="true"
                data-reached={index <= shown ? "" : undefined}
              />
            ))}
            <input
              ref={slider}
              type="range"
              min={0}
              max={Math.max(levels.length - 1, 0)}
              step={1}
              value={shown}
              aria-label={label}
              aria-valuetext={levels[shown]?.name}
              onChange={(event) => setPending(levels[Number(event.target.value)]?.id)}
              onPointerUp={commit}
              onKeyUp={(event) => {
                if (event.key !== "Escape" && event.key !== "Tab") commit();
              }}
            />
          </div>
        </dialog>
      )}
    </span>
  );
}
