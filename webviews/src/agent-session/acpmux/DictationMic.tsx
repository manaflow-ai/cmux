// The dictation mic as every composer draws it (the chat's and the New Tab page's): beside Send,
// unless `agentPane.showDictation` hides it. Its right-click offers Hide Dictation Button, and a
// right-click on the composer's button row offers Show (composerChrome.tsx), in every composer.
// While a session runs, the waveform and the finish key come in before it (DictationListening),
// in the same slot, so the row's fit (composerRowFit.ts) keeps them with the listening mic.
import React from "react";
import { HideableChrome } from "../../ui/HideableChrome";
import { useComposerChrome } from "./composerChrome";
import { isActive, type Dictation } from "./dictation";
import { DictationButton } from "./DictationButton";
import { DictationFinishButton, DictationWave } from "./DictationListening";

export function DictationMic({ dictation }: { dictation: Dictation }) {
  const { dictation: item } = useComposerChrome();
  const running = isActive(dictation.state);
  return (
    // A session still running ends with its button.
    <HideableChrome className="acpmux-mic-menu" item={item} onHide={() => dictation.cancel()}>
      {running && <DictationWave state={dictation.state} />}
      {running && <DictationFinishButton dictation={dictation} />}
      <DictationButton dictation={dictation} />
    </HideableChrome>
  );
}
