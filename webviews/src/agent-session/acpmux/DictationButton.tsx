// The mic next to Send: a microphone while idle, a live waveform while listening.
import React from "react";
import { MicIcon } from "./ComposerPickers";
import { DictationLevelMeter } from "./DictationLevelMeter";
import { isActive, type Dictation } from "./dictation";
import { useT } from "./i18n";
import { SHORTCUT_ACTIONS, tooltipProps, useShortcut } from "./shortcuts";

export function DictationButton({ dictation }: { dictation: Dictation }) {
  const t = useT();
  const { state } = dictation;
  const listening = state === "listening" || state === "finalizing";
  // Keep the state transition observable to assistive technology while the host is
  // starting the speech engine or committing the final transcript. `aria-pressed`
  // still communicates that the session can be stopped; busy adds the missing
  // in-progress signal without introducing another visible label into the bar.
  const busy = state === "starting" || state === "finalizing";
  const label = isActive(state) ? t("dictation.stop") : t("dictation.start");
  const shortcut = useShortcut(SHORTCUT_ACTIONS.toggleDictation);
  return (
    <button
      type="button"
      className="acpmux-mic"
      data-state={state}
      aria-label={label}
      aria-pressed={isActive(state)}
      aria-busy={busy || undefined}
      {...tooltipProps(label, shortcut)}
      // Keep focus and the selection in the prompt: that is where the words go.
      onMouseDown={(event) => event.preventDefault()}
      onClick={dictation.toggle}
    >
      {listening ? <DictationLevelMeter /> : <MicIcon />}
    </button>
  );
}
