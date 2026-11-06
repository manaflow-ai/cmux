// The mic next to Send: a microphone, lit (an accent-tinted square, dictation.css) while a session
// runs; Codex's look draws it lit as ChatGPT's Stop, a square. The waveform beside it is
// DictationListening's.
import React from "react";
import { MicIcon, StopIcon } from "./ComposerPickers";
import { useComposerLook } from "./composerLook";
import { isActive, type Dictation } from "./dictation";
import { useT } from "./i18n";
import { SHORTCUT_ACTIONS, tooltipProps, useShortcut } from "./shortcuts";

export function DictationButton({ dictation }: { dictation: Dictation }) {
  const t = useT();
  const { state } = dictation;
  // Keep the state transition observable to assistive technology while the host is
  // starting the speech engine or committing the final transcript. `aria-pressed`
  // still communicates that the session can be stopped; busy adds the missing
  // in-progress signal without introducing another visible label into the bar.
  const busy = state === "starting" || state === "finalizing";
  const label = isActive(state) ? t("dictation.stop") : t("dictation.start");
  const shortcut = useShortcut(SHORTCUT_ACTIONS.toggleDictation);
  const look = useComposerLook();
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
      {look === "codex" && isActive(state) ? <StopIcon /> : <MicIcon />}
    </button>
  );
}
