import { useMemo } from "react";
import type { HideableChromeItem } from "../../ui/HideableChrome";
import { MicIcon } from "./ComposerPickers";
import { showComposerControl, useComposerSettings } from "./composerSettings";
import { useT } from "./i18n";
import { setQueueing, useQueueing } from "./queueing";

export function useComposerChrome() {
  const t = useT();
  const { showDictation, showContextUsage } = useComposerSettings();
  const queueing = useQueueing();
  return useMemo(() => {
    const dictation: HideableChromeItem = {
      id: "dictation",
      hideLabel: t("dictation.hideButton"),
      showLabel: t("dictation.showButton"),
      icon: <MicIcon />,
      shown: showDictation,
      setShown: (show) => showComposerControl("showDictation", show),
    };
    const queue: HideableChromeItem = {
      id: "queueing",
      hideLabel: t("composer.queueingOff"),
      showLabel: t("composer.queueingOn"),
      shown: queueing,
      setShown: setQueueing,
    };
    const ring: HideableChromeItem = {
      id: "usage-ring",
      hideLabel: t("ring.menu.hide"),
      showLabel: t("ring.menu.show"),
      shown: showContextUsage,
      setShown: (show) => showComposerControl("showContextUsage", show),
    };
    return { dictation, ring, all: [dictation, ring, queue] as const };
  }, [t, showDictation, showContextUsage, queueing]);
}
