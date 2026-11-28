// The dictation mic as every composer draws it (the chat's and the New Tab page's): beside Send,
// unless `agentPane.showDictation` hides it. Its right-click offers Hide Dictation Button, and a
// right-click on the composer's button row offers Show (composerChrome.tsx), in every composer.
import React from "react";
import { HideableChrome } from "../../ui/HideableChrome";
import { useComposerChrome } from "./composerChrome";
import type { Dictation } from "./dictation";
import { DictationButton } from "./DictationButton";

export function DictationMic({ dictation }: { dictation: Dictation }) {
  const { dictation: item } = useComposerChrome();
  return (
    // A session still running ends with its button.
    <HideableChrome className="acpmux-mic-menu" item={item} onHide={() => dictation.cancel()}>
      <DictationButton dictation={dictation} />
    </HideableChrome>
  );
}
