// The dictation mic as every composer draws it (the chat's and the New Tab page's): beside Send,
// unless `agentPane.showDictation` hides it. Its right-click picks what it dictates with (cmux's
// own, macOS Dictation, or each dictation app this Mac has; dictationSources.ts) and offers Hide
// Dictation Button, and a right-click on the composer's button row offers Show
// (composerChrome.tsx), in every composer.
// While a session runs, its strip (DictationListening: the waveform, and Codex's ✕) comes in before
// it, in the same slot, so the row's fit (composerRowFit.ts) keeps them with the listening mic. The
// chat's composer draws the strip itself, before its Send (`strip={false}`), so Claude's look reads
// waveform, ↵, mic, as Claude's composer does.
import React, { useMemo } from "react";
import type { ContextMenuItem } from "../../ui/ContextMenu";
import { HideableChrome } from "../../ui/HideableChrome";
import { useComposerChrome } from "./composerChromeModel";
import { setDictationSource, useComposerSettings, type DictationSource } from "./composerSettings";
import { isActive, type Dictation } from "./dictation";
import { DictationButton } from "./DictationButton";
import { DictationStrip } from "./DictationListening";
import { dictationSourceName, useDictationApps } from "./dictationSources";
import { useT } from "./i18n";

export function DictationMic({ dictation, strip = true }: { dictation: Dictation; strip?: boolean }) {
  const { dictation: item } = useComposerChrome();
  const running = isActive(dictation.state);
  const sources = useDictationSourceItems();
  return (
    // A session still running ends with its button.
    <HideableChrome className="acpmux-mic-menu" item={item} menuItems={sources} onHide={() => dictation.cancel()}>
      {strip && <DictationStrip dictation={dictation} shown={running} />}
      <DictationButton dictation={dictation} />
    </HideableChrome>
  );
}

/// The mic menu's sources, the picked one checked: cmux, macOS Dictation, then each app this Mac
/// has. A picked app this Mac no longer lists stays, so the pick can be seen and changed.
function useDictationSourceItems(): ContextMenuItem[] {
  const t = useT();
  const { dictationSource } = useComposerSettings();
  const apps = useDictationApps();
  return useMemo(() => {
    const ids: DictationSource[] = ["cmux", "macos", ...apps.map((app) => app.id)];
    if (!ids.includes(dictationSource)) ids.push(dictationSource);
    return ids.map((id) => ({
      id: `dictation-source-${id}`,
      label: t("dictation.dictateWith", { name: dictationSourceName(id, t) }),
      checked: dictationSource === id,
      onSelect: () => setDictationSource(id),
    }));
  }, [t, dictationSource, apps]);
}
