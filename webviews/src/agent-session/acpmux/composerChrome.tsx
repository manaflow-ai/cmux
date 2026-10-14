// The composer's hideable controls (ui/HideableChrome.tsx), each hidden from its own right-click
// and shown again from the composer's button row, in every composer (composerSettings.ts): the
// dictation mic. The row draws no context ring (hq#1957 item 15 compact row), so it no longer
// offers one; showContextUsage now only says whether the model chip's tooltip names the usage.
import React, { useMemo } from "react";
import type { HideableChromeItem } from "../../ui/HideableChrome";
import { MicIcon } from "./ComposerPickers";
import { showComposerControl, useComposerSettings } from "./composerSettings";
import { useT } from "./i18n";

export function useComposerChrome() {
  const t = useT();
  const { showDictation } = useComposerSettings();
  return useMemo(() => {
    const dictation: HideableChromeItem = {
      id: "dictation",
      hideLabel: t("dictation.hideButton"),
      showLabel: t("dictation.showButton"),
      icon: <MicIcon />,
      shown: showDictation,
      setShown: (show) => showComposerControl("showDictation", show),
    };
    return { dictation, all: [dictation] as const };
  }, [t, showDictation]);
}
