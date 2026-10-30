import React, { useEffect, useRef } from "react";
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

/// The compact track's geometry (QuickModelMenu's model rows, Leo 2026-10-29: "i highly doubt you need
/// the effort levels spelled out everywhere... sliders are fine in many cases"). Fixed pixels, so every
/// stop centre is a whole pixel: 60px of travel divides evenly into 2 to 7 levels' 1 to 6 gaps (30,
/// 20, 15, 12, 10px), and the thumb's centre sits on each stop's centre, the ends included ("it was
/// just shit looking bc the circle center wasn't on the selection scenter", Leo 2026-10-29).
export const COMPACT_EFFORT_TRACK = { width: 72, thumb: 12, stop: 4 } as const;

/// A compact stop's centre, in whole pixels from the track's left edge: the travel starts and ends a
/// thumb radius in from the track's edges, so the thumb never overhangs the track at either end.
export function compactStopCenterX(index: number, stopCount: number): number {
  const inset = COMPACT_EFFORT_TRACK.thumb / 2;
  return Math.round(effortStopCenterX(inset, COMPACT_EFFORT_TRACK.width - 2 * inset, index, stopCount));
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
  compact = false,
  label,
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
  /// The model menu's one-line track (COMPACT_EFFORT_TRACK): whole-pixel stops, no Faster and Smarter
  /// line, no motion (it moves under the keyboard and the pointer, many times a day).
  compact?: boolean;
  /// The range's accessible name; the plain "Effort" by default.
  label?: string;
}) {
  const t = useT();
  const range = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (!focusOnMount) return;
    const frame = requestAnimationFrame(() => range.current?.focus({ preventScroll: true }));
    return () => cancelAnimationFrame(frame);
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
  const rangeInput = (
    <input
      ref={range}
      className="acpmux-effort-range"
      type="range"
      min={0}
      max={Math.max(efforts.length - 1, 0)}
      step={1}
      value={level}
      aria-label={label ?? t("effort.title")}
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
  );
  if (compact) {
    const { width, thumb, stop } = COMPACT_EFFORT_TRACK;
    const x = (index: number) => compactStopCenterX(index, efforts.length);
    // A level nobody has resolved (the chat runs a model this menu cannot name): no thumb and no
    // name, never a guess, until a stop is picked.
    const unset = at(current) < 0 && at(fallback) < 0;
    return (
      <span className="acpmux-effort-track" data-compact="" style={{ width }}>
        <span className="acpmux-effort-fill" style={{ width: unset ? 0 : x(level) }} />
        {efforts.map((choice, index) => (
          <span
            key={choice.id}
            className="acpmux-effort-stop"
            aria-hidden="true"
            data-level={choice.id}
            data-name={choice.name}
            data-at={!unset && index === level ? "" : undefined}
            data-filled={!unset && index < level ? "" : undefined}
            style={{ left: x(index) - stop / 2 }}
          />
        ))}
        {!unset && <span className="acpmux-effort-thumb" style={{ left: x(level) - thumb / 2 }} />}
        {rangeInput}
      </span>
    );
  }
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
        {rangeInput}
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
