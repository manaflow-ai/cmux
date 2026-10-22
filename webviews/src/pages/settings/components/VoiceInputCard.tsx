// Settings > Chief > Voice input (Leo's list): the message box's mic, which is the Debug toggle
// home.voiceInput itself. The host sends `voice_input` only where that tunable exists (DEV and
// NIGHTLY); Release has no row and keeps the mic's default.
import { useId } from "react";
import { useSettingsState, useStore } from "../context";
import { t } from "../strings";
import { Switch } from "../editors/ToggleEditor";
import { ResetSpacer } from "./ResetButton";

export function VoiceInputCard() {
  const store = useStore();
  const voice = useSettingsState().host?.voice_input;
  const labelId = useId();
  if (!voice) return null;
  return (
    <section className="group" data-card="voice-input">
      <div className="rows">
        <div className="row" tabIndex={-1}>
          <div className="row-main">
            <div className="row-label">
              <div className="row-title" id={labelId}>
                {t("settingsWindow.chief.voiceInput.title")}
              </div>
              <div className="row-help">{t("settingsWindow.chief.voiceInput.help")}</div>
            </div>
            <div className="row-control">
              <Switch
                checked={voice.on}
                disabled={false}
                labelId={labelId}
                onToggle={(next) => void store.setVoiceInput(next)}
              />
              <ResetSpacer />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
