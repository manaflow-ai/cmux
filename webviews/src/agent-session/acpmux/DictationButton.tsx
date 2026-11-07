// The mic next to Send: a microphone, lit (an accent-tinted square, dictation.css) while a session
// runs; Codex's look draws it lit as ChatGPT's Stop, a square. The waveform beside it is
// DictationListening's. When the person dictates with an app (`agentPane.dictationSource`,
// dictationSources.ts), the button wears that app's icon and its press sends the app's shortcut.
import React from "react";
import { useSourceIcon } from "./composer/sourceBadgeModel";
import { MicIcon, StopIcon } from "./ComposerPickers";
import { useComposerLook } from "./composerLook";
import { useComposerSettings } from "./composerSettings";
import { isActive, type Dictation } from "./dictation";
import { dictationSourceName, isAppSource, refreshDictationApps, useDictationApps } from "./dictationSources";
import { useT } from "./i18n";
import { SHORTCUT_ACTIONS, tooltipProps, useShortcut } from "./shortcuts";

export function DictationButton({ dictation }: { dictation: Dictation }) {
  const t = useT();
  const { state } = dictation;
  const { dictationSource } = useComposerSettings();
  const apps = useDictationApps();
  const app = isAppSource(dictationSource) ? apps.find((each) => each.id === dictationSource) : undefined;
  const icon = useSourceIcon(app?.bundleId);
  // Keep the state transition observable to assistive technology while the host is
  // starting the speech engine or committing the final transcript. `aria-pressed`
  // still communicates that the session can be stopped; busy adds the missing
  // in-progress signal without introducing another visible label into the bar.
  const busy = state === "starting" || state === "finalizing";
  const label = isActive(state)
    ? t("dictation.stop")
    : dictationSource === "cmux"
      ? t("dictation.start")
      : t("dictation.dictateWith", { name: dictationSourceName(dictationSource, t) });
  const shortcut = useShortcut(SHORTCUT_ACTIONS.toggleDictation);
  const look = useComposerLook();
  return (
    <button
      type="button"
      className="acpmux-mic"
      data-state={state}
      data-source={dictationSource === "cmux" ? undefined : dictationSource}
      aria-label={label}
      aria-pressed={isActive(state)}
      aria-busy={busy || undefined}
      {...tooltipProps(label, shortcut)}
      // Keep focus and the selection in the prompt: that is where the words go.
      onMouseDown={(event) => event.preventDefault()}
      // The menu lists the apps this Mac has now (one installed since the mic first showed).
      onContextMenu={refreshDictationApps}
      onClick={dictation.toggle}
    >
      {look === "codex" && isActive(state) ? (
        <StopIcon />
      ) : icon && !isActive(state) ? (
        <img className="acpmux-mic-app-icon" src={icon} alt="" width={16} height={16} draggable={false} />
      ) : (
        <MicIcon />
      )}
    </button>
  );
}
