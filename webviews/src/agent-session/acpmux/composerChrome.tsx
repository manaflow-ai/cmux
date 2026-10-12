// The composer's hideable controls (ui/HideableChrome.tsx): the dictation mic and the context usage
// ring, each hidden from its own right-click and shown again from the composer's button row, in
// every composer (composerSettings.ts).
import React, { useMemo } from "react";
import type { HideableChromeItem } from "../../ui/HideableChrome";
import { MicIcon, RingIcon } from "./ComposerPickers";
import { showComposerControl, useComposerSettings } from "./composerSettings";
import { useT } from "./i18n";

export function useComposerChrome() {
  const t = useT();
  const { showDictation, showContextUsage } = useComposerSettings();
  return useMemo(() => {
    const dictation: HideableChromeItem = {
      id: "dictation",
      hideLabel: t("dictation.hideButton"),
      showLabel: t("dictation.showButton"),
      icon: <MicIcon />,
      shown: showDictation,
      setShown: (show) => showComposerControl("showDictation", show),
    };
    const contextUsage: HideableChromeItem = {
      id: "context-usage",
      hideLabel: t("context.hide"),
      showLabel: t("context.show"),
      icon: <RingIcon />,
      shown: showContextUsage,
      setShown: (show) => showComposerControl("showContextUsage", show),
    };
    return { dictation, contextUsage, all: [contextUsage, dictation] as const };
  }, [t, showDictation, showContextUsage]);
}
