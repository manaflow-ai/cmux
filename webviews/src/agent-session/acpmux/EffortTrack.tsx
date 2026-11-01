import React, { useLayoutEffect, useRef } from "react";
import type { Choice } from "./ComposerPickers";
import type { ReasoningSliderStyle } from "./composerSettings";
import { useT } from "./i18n";

/** The normalized position of a discrete stop, including the track endpoints. */
export function effortStopShare(index: number, stopCount: number): number {
  return stopCount > 1 ? index / (stopCount - 1) : 0;
}

/** The x-coordinate of a thumb or stop center. Both use this endpoint-inclusive geometry. */
export function effortStopCenterX(trackLeft: number, trackWidth: number, index: number, stopCount: number): number {
  return trackLeft + trackWidth * effortStopShare(index, stopCount);
}

/// The effort's stepped slider: a native range input (arrow keys, Home and End step it), drawn
/// as a track with one stop per level the agent offers (a click on the track jumps to the
/// nearest stop), over its ends (Faster, Smarter) and the level the model recommends. The model
/// picker's reasoning panel draws it.
export function EffortTrack({
  efforts,
  current,
  onPick,
  onEscape,
  focusOnMount = false,
  fallback,
  onRangeKey,
  onRangeClick,
  sliderStyle = "accent",
}: {
  efforts: Choice[];
  current?: string;
  /// Where the thumb rests while `current` is not one of `efforts` (the agent's own default):
  /// the reasoning menu's slider rests on the recommended level. Without it, the first level.
  fallback?: string;
  onPick(value: string): void;
  /// Escape on the slider hands focus back (the popover closes, a menu steps back).
  onEscape?(): void;
  /// Sees the slider's keys first (the reasoning menu keeps its stepping keys from the menu's rows).
  onRangeKey?(event: React.KeyboardEvent<HTMLInputElement>): void;
  /// A click on the slider, after any change it made (the reasoning menu commits the resting level).
  onRangeClick?(): void;
  /// Focus the native range after its popup mounts so keyboard stepping starts on the slider.
  focusOnMount?: boolean;
  /// Visual treatment for the opt-in reasoning slider.
  sliderStyle?: ReasoningSliderStyle;
}) {
  const t = useT();
  const range = useRef<HTMLInputElement>(null);
  useLayoutEffect(() => {
    if (focusOnMount) range.current?.focus({ preventScroll: true });
  }, [focusOnMount]);
  const at = (id: string | undefined) => efforts.findIndex((choice) => choice.id === id);
  const level = Math.max(0, at(current) >= 0 ? at(current) : at(fallback));
  const name = efforts[level]?.name ?? t("effort.title");
  const recommended = efforts.find((choice) => choice.recommended);
  const pick = (index: number) => {
    const choice = efforts[index];
    if (choice && choice.id !== current) onPick(choice.id);
  };
  const share = effortStopShare(level, efforts.length);
  return (
    <>
      <div
        className="acpmux-effort-track"
        data-slider-style={sliderStyle}
        style={{ "--acpmux-effort": share } as React.CSSProperties}
      >
        <span className="acpmux-effort-fill" />
        {efforts.map((choice, index) =>
          index === level ? null : (
            <span
              key={choice.id}
              className="acpmux-effort-stop"
              aria-hidden="true"
              style={{ "--acpmux-stop": effortStopShare(index, efforts.length) } as React.CSSProperties}
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
          aria-valuetext={efforts[level]?.recommended ? t("effort.valueRecommended", { level: name }) : name}
          onChange={(event) => pick(Number(event.target.value))}
          onClick={() => onRangeClick?.()}
          onKeyDown={(event) => {
            onRangeKey?.(event);
            if (event.key !== "Escape" || !onEscape) return;
            event.preventDefault();
            event.stopPropagation();
            onEscape();
          }}
        />
      </div>
      {/* Claude's slider reads from Faster to Smarter, with the model's own pick named. */}
      <div className="acpmux-effort-ends" aria-hidden="true">
        <span className="acpmux-effort-faster">{t("effort.faster")}</span>
        {recommended && (
          <span className="acpmux-effort-recommended">{t("effort.recommendedLevel", { level: recommended.name })}</span>
        )}
        <span className="acpmux-effort-smarter">{t("effort.smarter")}</span>
      </div>
    </>
  );
}
