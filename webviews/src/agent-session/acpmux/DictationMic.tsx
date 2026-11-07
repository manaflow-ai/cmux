// The dictation mic as every composer draws it (the chat's and the New Tab page's): beside Send,
// unless `agentPane.showDictation` hides it. Its right-click offers Hide Dictation Button, and a
// right-click on the composer's button row offers Show (composerChrome.tsx), in every composer.
// While a session runs, its strip (DictationListening: the waveform, and Codex's ✕) comes in before
// it, in the same slot, so the row's fit (composerRowFit.ts) keeps them with the listening mic. The
// chat's composer draws the strip itself, before its Send (`strip={false}`), so Claude's look reads
// waveform, ↵, mic, as Claude's composer does.
import React from "react";
import { HideableChrome } from "../../ui/HideableChrome";
import { useComposerChrome } from "./composerChrome";
import { isActive, type Dictation } from "./dictation";
import { DictationButton } from "./DictationButton";
import { DictationStrip } from "./DictationListening";

export function DictationMic({ dictation, strip = true }: { dictation: Dictation; strip?: boolean }) {
  const { dictation: item } = useComposerChrome();
  const running = isActive(dictation.state);
  return (
    // A session still running ends with its button.
    <HideableChrome className="acpmux-mic-menu" item={item} onHide={() => dictation.cancel()}>
      {running && strip && <DictationStrip dictation={dictation} />}
      <DictationButton dictation={dictation} />
    </HideableChrome>
  );
}
