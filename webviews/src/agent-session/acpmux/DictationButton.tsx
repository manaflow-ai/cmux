// The mic next to Send: a microphone, lit (an accent-tinted square, dictation.css) while a session
// runs; Codex's look draws it lit as ChatGPT's Stop, a square. The waveform beside it is
// DictationListening's. When the person dictates with an app (`agentPane.dictationSource`,
// dictationSources.ts), the button wears that app's icon and its press sends the app's shortcut.
// While another app holds the microphone and this composer has the keyboard (outsideDictation.ts),
// bars take the glyph's place and the tooltip names the app: the measured level when the host
// meters it, three drawn bars otherwise. The button keeps its size, its press and its focus
// behavior, so the composer goes on as before.
import React, { useRef } from "react";
import { useSourceIcon } from "./composer/sourceBadgeModel";
import { MicIcon, StopIcon } from "./ComposerPickers";
import { useComposerLook } from "./composerLook";
import { useComposerSettings } from "./composerSettings";
import { isActive, type Dictation } from "./dictation";
import { dictationSourceName, isAppSource, refreshDictationApps, useDictationApps } from "./dictationSources";
import { OutsideLevelBars } from "./DictationListening";
import { useT } from "./i18n";
import { useOutsideDictation } from "./outsideDictation";
import { SHORTCUT_ACTIONS, tooltipProps, useShortcut } from "./shortcuts";

export function DictationButton({ dictation }: { dictation: Dictation }) {
  const t = useT();
  const { state } = dictation;
  const { dictationSource } = useComposerSettings();
  const apps = useDictationApps();
  const app = isAppSource(dictationSource) ? apps.find((each) => each.id === dictationSource) : undefined;
  const icon = useSourceIcon(app?.bundleId);
  const button = useRef<HTMLButtonElement>(null);
  const outside = useOutsideDictation(button);
  // cmux's own session draws its own waveform beside the mic; the mark is for other apps only.
  const elsewhere = outside.active && !isActive(state);
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
  const elsewhereText = elsewhere
    ? outside.name
      ? t("dictation.outside", { name: outside.name })
      : t("dictation.outsideUnknown")
    : undefined;
  const tooltip = elsewhereText ? `${label}\n${elsewhereText}` : label;
  const look = useComposerLook();
  return (
    <button
      ref={button}
      type="button"
      className="acpmux-mic"
      data-state={state}
      data-source={dictationSource === "cmux" ? undefined : dictationSource}
      data-outside={elsewhere || undefined}
      aria-label={label}
      aria-pressed={isActive(state)}
      aria-busy={busy || undefined}
      {...tooltipProps(tooltip, shortcut)}
      // Keep focus and the selection in the prompt: that is where the words go.
      onMouseDown={(event) => event.preventDefault()}
      // The menu lists the apps this Mac has now (one installed since the mic first showed).
      onContextMenu={refreshDictationApps}
      onClick={dictation.toggle}
    >
      {elsewhere && outside.metered ? (
        <OutsideLevelBars />
      ) : elsewhere ? (
        <span className="acpmux-mic-outside" aria-hidden="true">
          <span />
          <span />
          <span />
        </span>
      ) : null}
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
