// Agents > Computer Use Setup: the grants of the cmux Computer Use helper (macOS gives
// Accessibility and Screen Recording to the helper, not to cmux), from the host lists'
// `computer_use` (the app's ComputerUseSetup, the same state the palette action and onboarding
// show), live through cmux.settings.host.changed. Buttons run the catalog actions.
import { useSettingsState, useStore } from "../context";
import type { ComputerUseState } from "../ops";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

function phaseText(state: ComputerUseState): string {
  if (state.phase === "ready") {
    return state.accessibility && state.screen_recording
      ? t("settingsWindow.computerUse.phase.ready")
      : t("settingsWindow.computerUse.phase.missing");
  }
  return t(`settingsWindow.computerUse.phase.${state.phase}`);
}

function Grant({ granted }: { granted: boolean | null }) {
  if (granted === null) return <span className="badge">{t("settingsWindow.computerUse.unknown")}</span>;
  return granted ? (
    <span className="badge" data-granted="true">
      {t("settingsWindow.computerUse.allowed")}
    </span>
  ) : (
    <span className="badge badge-warning" data-granted="false">
      {t("settingsWindow.computerUse.notAllowed")}
    </span>
  );
}

export function ComputerUseCard() {
  const store = useStore();
  const { host } = useSettingsState();
  const state = host?.computer_use;
  if (!state || state.phase === "disabled_by_policy") return null;
  const row = (
    pane: "accessibility" | "screenRecording",
    granted: boolean | null,
    action: "palette.computerUse.accessibility" | "palette.computerUse.screenRecording",
  ) => (
    <ActionRow title={t(`settingsWindow.computerUse.${pane}`)} help={t(`settingsWindow.computerUse.${pane}.help`)}>
      <Grant granted={granted} />
      <button type="button" className="button" data-action={action} onClick={() => void store.runAction(action)}>
        {t("settingsWindow.computerUse.openSettings")}
      </button>
    </ActionRow>
  );
  return (
    <section className="group" data-card="computer-use" data-phase={state.phase}>
      <h3 className="group-title">{t("settingsWindow.computerUse.title")}</h3>
      <div className="row-help">
        {state.helper
          ? t("settingsWindow.computerUse.helpNamed", state.helper)
          : t("settingsWindow.computerUse.help")}
      </div>
      <div className="rows">
        {row("accessibility", state.accessibility, "palette.computerUse.accessibility")}
        {row("screenRecording", state.screen_recording, "palette.computerUse.screenRecording")}
        <ActionRow title={t("settingsWindow.computerUse.status")} help={phaseText(state)}>
          <button
            type="button"
            className="button"
            data-action="palette.computerUse.setup"
            onClick={() => void store.runAction("palette.computerUse.setup")}
          >
            {t("settingsWindow.computerUse.setUp")}
          </button>
        </ActionRow>
      </div>
    </section>
  );
}
