// What a running dictation adds before the mic, as Claude's composer draws it (Leo's reference,
// 2026-10-20): a waveform of thin bars that follows the mic level and fades to dots at both ends,
// then a finish key (the Return glyph) that ends the session and keeps its words.
import React, { useSyncExternalStore } from "react";
import { readLevel, subscribeLevel, type Dictation } from "./dictation";
import "./dictation.css";
import { useT } from "./i18n";
import { tooltipProps } from "./shortcuts";

/// Resting dots at each end of the waveform.
const END_DOTS = 3;
const ends = Array.from({ length: END_DOTS }, (_, index) => index);

/// How far bar `index` of `count` may rise: the middle bars the most, so the wave tapers into the
/// dots at its ends.
function reach(index: number, count: number): number {
  return 0.4 + 0.6 * Math.sin((Math.PI * (index + 0.5)) / count);
}

/// The recent input levels as bars, newest on the right. Each bar's `--level` (0...1) sets its
/// height in dictation.css; at 0 a bar is a dot like the ends.
export function DictationWave({ state }: { state: Dictation["state"] }) {
  const samples = useSyncExternalStore(subscribeLevel, readLevel);
  return (
    <span className="acpmux-dictation-wave" data-state={state} aria-hidden="true">
      {ends.map((index) => (
        <span key={`lead-${index}`} data-dot="" />
      ))}
      {samples.map((sample, index) => (
        <span
          key={index}
          data-bar=""
          style={
            {
              "--level": Math.min(1, Math.max(0, sample * 1.6 * reach(index, samples.length))).toFixed(3),
            } as React.CSSProperties
          }
        />
      ))}
      {ends.map((index) => (
        <span key={`tail-${index}`} data-dot="" />
      ))}
    </span>
  );
}

/// ⏎: ends the session and keeps its words (`dictation.stop`); the mic beside it does the same,
/// and Esc drops them.
export function DictationFinishButton({ dictation }: { dictation: Dictation }) {
  const t = useT();
  const label = t("dictation.finish");
  return (
    <button
      type="button"
      className="acpmux-dictation-finish"
      aria-label={label}
      // The last words are still landing: nothing is left to finish.
      disabled={dictation.state === "finalizing"}
      {...tooltipProps(label, undefined)}
      // Keep focus and the selection in the prompt, as the mic does.
      onMouseDown={(event) => event.preventDefault()}
      onClick={dictation.finish}
    >
      <ReturnKeyIcon />
    </button>
  );
}

const ReturnKeyIcon = () => (
  <svg
    className="acpmux-icon"
    width={16}
    height={16}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.5}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    <path d="M13 3.5v4.75a1.75 1.75 0 0 1-1.75 1.75H3.5" />
    <path d="M6.25 7.25 3.5 10l2.75 2.75" />
  </svg>
);
