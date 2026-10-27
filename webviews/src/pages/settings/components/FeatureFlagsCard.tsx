// Experimental > Feature Flags (feature featureFlagsCard, off by default): every declared feature
// (schemas/features/features.d) with its state and the input that decided it, as chrome://flags
// lists each flag (components/flags_ui/flags_state.cc). Data: the host lists' `features`, the
// socket's `features.list` (`cmux settings feature-flags`) plus the next launch's local choices.
// Features resolve once per launch, so a choice applies at the next start, as about:flags asks to
// relaunch. Only DEV and NIGHTLY take local choices (`local_overrides`); elsewhere it is read-only.
import { useId } from "react";
import { useSettingsState, useStore } from "../context";
import { Select } from "../editors/Select";
import type { FeatureFlag, FeatureFlagsState, FeatureSource } from "../ops";
import { t } from "../strings";

const SOURCE_KEYS: Record<FeatureSource, string> = {
  policy: "settingsWindow.featureFlags.source.policy",
  env: "settingsWindow.featureFlags.source.env",
  local: "settingsWindow.featureFlags.source.local",
  remote: "settingsWindow.featureFlags.source.remote",
  trial: "settingsWindow.featureFlags.source.trial",
  default: "settingsWindow.featureFlags.source.default",
};

const onOff = (on: boolean) => t(on ? "settingsWindow.featureFlags.on" : "settingsWindow.featureFlags.off");

type Choice = "automatic" | "on" | "off";

const choiceOf = (value: boolean | undefined): Choice => (value === undefined ? "automatic" : value ? "on" : "off");

/** Whether the next launch's local choice differs from the one this launch applied. */
function changesAtRestart(feature: FeatureFlag, next: boolean | undefined): boolean {
  const applied = feature.source === "local" ? feature.state === "on" : undefined;
  return applied !== next;
}

function safeModeText(state: FeatureFlagsState): string | null {
  if (state.safe_mode?.level === "last-known-good") return t("settingsWindow.featureFlags.safeMode.lastKnownGood");
  if (state.safe_mode?.level === "no-remote") return t("settingsWindow.featureFlags.safeMode.noRemote");
  return null;
}

function FeatureRow({ feature, state }: { feature: FeatureFlag; state: FeatureFlagsState }) {
  const store = useStore();
  const labelId = useId();
  const next = state.next_local[feature.name];
  const status = [
    onOff(feature.state === "on"),
    t("settingsWindow.featureFlags.source", t(SOURCE_KEYS[feature.source] ?? SOURCE_KEYS.default)),
    t("settingsWindow.featureFlags.channelDefault", onOff(feature.default)),
  ];
  return (
    <div className="row" tabIndex={-1} data-feature={feature.name} data-state={feature.state}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {feature.name}
          </div>
          <div className="row-help">{feature.description}</div>
          <div className="row-help" data-feature-status>
            {status.join(" · ")}
          </div>
          {state.local_overrides && changesAtRestart(feature, next) && (
            <div className="row-help" data-feature-restart>
              {t("settingsWindow.featureFlags.restart")}
            </div>
          )}
        </div>
        {state.local_overrides && (
          <div className="row-control">
            <Select
              value={choiceOf(next)}
              disabled={false}
              labelId={labelId}
              onChange={(choice) =>
                void store.setLocalFeature(feature.name, choice === "automatic" ? null : choice === "on")
              }
            >
              <option value="automatic">{t("settingsWindow.featureFlags.choice.automatic")}</option>
              <option value="on">{t("settingsWindow.featureFlags.on")}</option>
              <option value="off">{t("settingsWindow.featureFlags.off")}</option>
            </Select>
          </div>
        )}
      </div>
    </div>
  );
}

export function FeatureFlagsCard() {
  const state = useSettingsState().host?.features;
  if (!state) return null;
  const safeMode = safeModeText(state);
  return (
    <section className="group" data-card="feature-flags" data-local={state.local_overrides}>
      <h3 className="group-title">{t("settingsWindow.featureFlags.title")}</h3>
      <div className="row-help">
        {t("settingsWindow.featureFlags.help")}{" "}
        {t(
          state.local_overrides ? "settingsWindow.featureFlags.helpLocal" : "settingsWindow.featureFlags.helpReadOnly",
        )}
      </div>
      {safeMode && (
        <div className="row-help" data-feature-safe-mode>
          {safeMode}
        </div>
      )}
      {state.unknown_names.length > 0 && (
        <div className="row-help" data-feature-unknown>
          {t("settingsWindow.featureFlags.unknown", state.unknown_names.join(", "))}
        </div>
      )}
      <div className="rows">
        {state.features.length === 0 ? (
          <div className="row">
            <div className="empty">{t("settingsWindow.featureFlags.none")}</div>
          </div>
        ) : (
          state.features.map((feature) => <FeatureRow key={feature.name} feature={feature} state={state} />)
        )}
      </div>
    </section>
  );
}
