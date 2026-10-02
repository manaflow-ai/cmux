import React, { useEffect, useRef } from "react";
import type { Choice } from "./ComposerPickers";
import { t } from "./i18n";

/// The effort's stepped slider: a native range input (arrow keys, Home and End step it), drawn
/// as a track with one stop per level the agent offers (a click on the track jumps to the
/// nearest stop). The effort popover and the model picker both draw it.
export function EffortTrack({
  efforts,
  current,
  onPick,
  onEscape,
  autoFocus = false,
}: {
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  /// Escape on the slider hands focus back (the popover closes, a menu steps back).
  onEscape?(): void;
  autoFocus?: boolean;
}) {
  const range = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (autoFocus) range.current?.focus();
  }, [autoFocus]);
  const level = Math.max(
    0,
    efforts.findIndex((choice) => choice.id === current),
  );
  const name = efforts[level]?.name ?? t("effort.title");
  const pick = (index: number) => {
    const choice = efforts[index];
    if (choice && choice.id !== current) onPick(choice.id);
  };
  const share = efforts.length > 1 ? level / (efforts.length - 1) : 0;
  return (
    <div className="acpmux-effort-track" style={{ "--acpmux-effort": share } as React.CSSProperties}>
      <span className="acpmux-effort-fill" />
      {efforts.map((choice, index) =>
        index === level ? null : (
          <span
            key={choice.id}
            className="acpmux-effort-stop"
            aria-hidden="true"
            style={{ "--acpmux-stop": efforts.length > 1 ? index / (efforts.length - 1) : 0 } as React.CSSProperties}
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
          if (event.key !== "Escape" || !onEscape) return;
          event.preventDefault();
          event.stopPropagation();
          onEscape();
        }}
      />
    </div>
  );
}
