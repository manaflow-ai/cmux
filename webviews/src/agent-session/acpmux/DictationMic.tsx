// The dictation mic as every composer draws it (the chat's and the New Tab page's): beside Send,
// unless `agentPane.showDictation` hides it. Its right-click hides it in every composer; Settings
// shows it again (composerSettings.ts).
import React from "react";
import { ContextMenu } from "../../ui/ContextMenu";
import { setComposerSettings, useComposerSettings } from "./composerSettings";
import type { Dictation } from "./dictation";
import { DictationButton } from "./DictationButton";
import { useT } from "./i18n";

export function DictationMic({
  dictation,
  onShowDictation,
}: {
  dictation: Dictation;
  /// Writes the setting (`pane.showDictation`); the host pushes it back to every page.
  onShowDictation?: (show: boolean) => void;
}) {
  const t = useT();
  const { showDictation } = useComposerSettings();
  if (!showDictation) return null;
  const hide = () => {
    // A session still running ends with its button.
    dictation.cancel();
    setComposerSettings({ showDictation: false });
    onShowDictation?.(false);
  };
  return (
    <ContextMenu className="acpmux-mic-menu" items={[{ id: "hide", label: t("dictation.hideButton"), onSelect: hide }]}>
      <DictationButton dictation={dictation} />
    </ContextMenu>
  );
}
