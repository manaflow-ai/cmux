// The mic next to Send: a microphone while idle, a live waveform while listening.
import React from "react";
import { MicIcon } from "./ComposerPickers";
import { DictationLevelMeter } from "./DictationLevelMeter";
import { isActive, type Dictation } from "./dictation";
import { t } from "./i18n";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "./shortcuts";

export function DictationButton({ dictation }: { dictation: Dictation }) {
  const { state } = dictation;
  const listening = state === "listening" || state === "finalizing";
  const label = isActive(state) ? t("dictation.stop") : t("dictation.start");
  const shortcut = useShortcut(SHORTCUT_ACTIONS.toggleDictation);
  return (
    <button
      type="button"
      className="acpmux-mic"
      data-state={state}
      aria-label={label}
      aria-pressed={isActive(state)}
      title={withShortcut(label, shortcut)}
      // Keep focus and the selection in the prompt: that is where the words go.
      onMouseDown={(event) => event.preventDefault()}
      onClick={dictation.toggle}
    >
      {listening ? <DictationLevelMeter /> : <MicIcon />}
    </button>
  );
}
