// Agents > Computer Use: one card for everything Computer Use (#28997). The switch that turns it on
// and off (computerUse.enabled) and Set Up Computer Use…, which starts the guided setup (the same
// onboarding step as the palette's Computer Use Setup), come first. Then the grants of the cmux
// Computer Use helper (macOS gives Accessibility and Screen Recording to the helper, not to cmux),
// from the host lists' `computer_use` (the app's ComputerUseSetup), live through
// cmux.settings.host.changed, and then the driver and live preview rows. The schema group
// `settings.group.computerUse` is not drawn a second time (SectionView, COMPUTER_USE_ROWS).
import { useSettingsState, useStore } from "../context";
import type { ComputerUseState } from "../ops";
import { rowsByKey } from "../schema";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";
import { SettingRow } from "./SettingRow";

export const COMPUTER_USE_ENABLED = "computerUse.enabled";
const COMPUTER_USE_DRIVER = "computerUse.driver";
const COMPUTER_USE_LIVE_PREVIEW = "computerUse.livePreview";

/** The schema rows the card draws itself. */
export const COMPUTER_USE_ROWS: ReadonlySet<string> = new Set([
  COMPUTER_USE_ENABLED,
  COMPUTER_USE_DRIVER,
  COMPUTER_USE_LIVE_PREVIEW,
]);

function helperText(state: ComputerUseState): string {
  if (state.host_unverified) return t("settingsWindow.computerUse.hostUnverified");
  if (state.phase === "ready") {
    return state.accessibility && state.screen_recording
      ? t("settingsWindow.computerUse.phase.ready")
      : t("settingsWindow.computerUse.phase.missing");
  }
  return t(`settingsWindow.computerUse.phase.${state.phase}`);
}

// Driver "upstream" in a build without its helper runs the legacy helper: say so first.
function phaseText(state: ComputerUseState): string {
  const text = helperText(state);
  return state.upstream_fallback ? `${t("settingsWindow.computerUse.upstreamFallback")} ${text}` : text;
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

type GrantAction = "palette.computerUse.accessibility" | "palette.computerUse.screenRecording";

export function ComputerUseCard({ focus = null }: { focus?: string | null }) {
  const store = useStore();
  const { host } = useSettingsState();
  const state = host?.computer_use ?? null;
  // A policy lock (DisabledFeatures) turns Computer Use off for this Mac: setup and grants do not
  // apply, but the rows still show (as search lists them), so a deep link lands on its row.
  const locked = state?.phase === "disabled_by_policy";
  const failed = state?.phase === "failed";
  const off = state?.phase === "off";
  const row = (key: string) => {
    const schemaRow = rowsByKey.get(key);
    return schemaRow ? <SettingRow row={schemaRow} focused={focus === key} /> : null;
  };
  const run = (action: Parameters<typeof store.runAction>[0]) => void store.runAction(action);
  const grant = (pane: "accessibility" | "screenRecording", granted: boolean | null, action: GrantAction) => (
    <ActionRow title={t(`settingsWindow.computerUse.${pane}`)} help={t(`settingsWindow.computerUse.${pane}.help`)}>
      <Grant granted={granted} />
      <button type="button" className="button" data-action={action} onClick={() => run(action)}>
        {t("settingsWindow.computerUse.openSettings")}
      </button>
    </ActionRow>
  );
  return (
    <section className="group" data-card="computer-use" data-phase={state?.phase ?? "unknown"}>
      <h3 className="group-title">{t("settings.group.computerUse")}</h3>
      <div className="rows">
        {row(COMPUTER_USE_ENABLED)}
        {/* The guided setup: it offers to turn Computer Use on, then walks each grant. */}
        {!locked && (
          <ActionRow
            title={t("settingsWindow.computerUse.setUpTitle")}
            help={state && !off ? phaseText(state) : t("settingsWindow.computerUse.setUpHelp")}
          >
            {failed ? (
              <button
                type="button"
                className="button"
                data-action="palette.computerUse.restart"
                onClick={() => run("palette.computerUse.restart")}
              >
                {t("settingsWindow.computerUse.restartHelper")}
              </button>
            ) : (
              <button
                type="button"
                className="button"
                data-action="palette.computerUse.setup"
                onClick={() => run("palette.computerUse.setup")}
              >
                {t("settingsWindow.computerUse.setUp")}
              </button>
            )}
          </ActionRow>
        )}
        {state &&
          !locked &&
          !failed &&
          !off &&
          grant("accessibility", state.accessibility, "palette.computerUse.accessibility")}
        {state &&
          !locked &&
          !failed &&
          !off &&
          grant("screenRecording", state.screen_recording, "palette.computerUse.screenRecording")}
        {row(COMPUTER_USE_DRIVER)}
        {row(COMPUTER_USE_LIVE_PREVIEW)}
      </div>
    </section>
  );
}
