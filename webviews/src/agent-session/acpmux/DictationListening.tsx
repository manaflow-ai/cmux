// What a running dictation adds to the composer's row: a compact solid pill holding a waveform of
// thin bars that follows the mic level and fades to dots at both ends (Leo 2026-11-08: "the
// waveform thing, like, that—are you able to have it be, like, the [...] black pill?"). The pill
// follows the theme: dark in a dark theme, its light counterpart in a light one. It comes in and
// leaves on the shared presence motion (ui/presence.ts), in the slot the wave always had, so the
// composer's row keeps its height and its other controls stay put. It has no send of its own (Leo 2026-11-05: "The dictate
// button has its own send button. We don't need that."): the composer's one Send ends the session
// and sends, and the lit mic stops it. Claude's look draws the waveform, Send's ↵ and the lit mic,
// as Claude's composer does; Codex's adds ChatGPT's ✕ before the waveform, which drops the words
// as Esc does, and draws the lit mic as Stop (DictationButton).
import React, { useSyncExternalStore } from "react";
import { usePresence } from "../../ui/presence";
import { useComposerLook } from "./composerLook";
import { readLevel, subscribeLevel, type Dictation } from "./dictation";
import "./dictation.css";
import { useT } from "./i18n";
import { readOutsideLevel, subscribeOutsideLevel } from "./outsideDictation";
import { tooltipProps } from "./shortcuts";

/// Resting dots at each end of the waveform.
const END_DOTS = 2;
const ends = Array.from({ length: END_DOTS }, (_, index) => index);

/// How far bar `index` of `count` may rise: the middle bars the most, so the wave tapers into the
/// dots at its ends.
function reach(index: number, count: number): number {
  return 0.4 + 0.6 * Math.sin((Math.PI * (index + 0.5)) / count);
}

/// Bar `index`'s `--level`, as the waveform scales a sample.
const barLevel = (sample: number, index: number, count: number) =>
  Math.min(1, Math.max(0, sample * 1.6 * reach(index, count))).toFixed(3);

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
              "--level": barLevel(sample, index, samples.length),
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

/// Another app's measured input level in the mic's place (outsideDictation.ts), drawn as the
/// waveform's bars so it reads as cmux's own: newest on the right, each bar's `--level` its height.
export function OutsideLevelBars() {
  const samples = useSyncExternalStore(subscribeOutsideLevel, readOutsideLevel);
  return (
    <span className="acpmux-mic-level" aria-hidden="true">
      {samples.map((sample, index) => (
        <span
          key={index}
          data-bar=""
          style={{ "--level": barLevel(sample, index, samples.length) } as React.CSSProperties}
        />
      ))}
    </span>
  );
}

/// The running session's part of the row: Codex's ✕, then the waveform in its pill. `shown` is
/// whether a session runs; the strip stays while its exit plays, then leaves the row.
export function DictationStrip({ dictation, shown }: { dictation: Dictation; shown: boolean }) {
  const look = useComposerLook();
  const presence = usePresence(shown, "right", { appear: true });
  if (!presence.present) return null;
  return (
    <>
      {look === "codex" && <DictationCancelButton dictation={dictation} leaving={presence.leaving} />}
      <span className="acpmux-dictation-pill" {...presence.props}>
        <DictationWave state={dictation.state} />
      </span>
    </>
  );
}

/// ✕: ends the session and drops its words (`dictation.cancel`), as Esc does; ChatGPT's, at the
/// left of its dictation row.
/// While the pill leaves, the button keeps its slot (inert, fading with it) so the row moves once.
export function DictationCancelButton({ dictation, leaving = false }: { dictation: Dictation; leaving?: boolean }) {
  const t = useT();
  const label = t("dictation.cancel");
  return (
    <button
      type="button"
      className="acpmux-dictation-cancel"
      data-leaving={leaving || undefined}
      disabled={leaving}
      tabIndex={leaving ? -1 : undefined}
      aria-label={label}
      {...tooltipProps(label, undefined)}
      // Keep focus and the selection in the prompt, as the mic does.
      onMouseDown={(event) => event.preventDefault()}
      onClick={dictation.cancel}
    >
      <CancelIcon />
    </button>
  );
}

const CancelIcon = () => (
  <svg
    className="acpmux-icon"
    width={16}
    height={16}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.5}
    strokeLinecap="round"
    aria-hidden="true"
    focusable="false"
  >
    <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" />
  </svg>
);
