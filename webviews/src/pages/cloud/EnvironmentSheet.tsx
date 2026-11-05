import { useSyncExternalStore } from "react";
import { Sheet } from "../../ui/Sheet";
import { DialogButton, keyedIconProps } from "../../ui/DialogButton";
import type { Strings } from "../shared/i18n";
import { EnvironmentNetwork, EnvironmentScript, EnvironmentValues } from "./EnvironmentFields";
import type { EnvironmentSection } from "./environmentModel";
import type { EnvironmentState, EnvironmentStore } from "./environmentStore";
import { L } from "./strings";
import "./environment.css";

const errorKeys: Record<NonNullable<EnvironmentState["error"]>, string> = {
  load: L.envLoadFailed,
  save: L.envSaveFailed,
  missing: L.envDefaultMissing,
  name: L.envNameRequired,
  names: L.envInvalidNames,
  script: L.envScriptTooLarge,
  file: L.envFileFailed,
  copy: L.envCopyFailed,
  secret: L.envSecretRequired,
};
const sections = {
  overview: L.envTitle,
  network: L.envNetwork,
  secrets: L.envSecrets,
  script: L.envScript,
  variables: L.envVariables,
};

export function EnvironmentSheet({ store, strings }: { store: EnvironmentStore; strings: Strings }) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const { draft, original, section } = state;
  const row = (target: EnvironmentSection, detail: string) => (
    <button type="button" className="env-drill" onClick={() => store.section(target)}>
      <span>
        <span className="env-row-title">{t(sections[target])}</span>
        <span className="env-row-detail">{detail}</span>
      </span>
      <span aria-hidden="true">›</span>
    </button>
  );
  return (
    <Sheet
      open={state.open}
      onOpenChange={(open) => !open && store.close()}
      label={t(sections[section])}
      className="ui-glass ui-glass-floats cloud-environment-sheet"
      backdropClassName="cloud-environment-backdrop"
      side="top"
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void store.save();
        }}
      >
        <header className="env-heading">
          {section !== "overview" && (
            <button
              type="button"
              className="env-icon"
              aria-label={t(L.envBack)}
              onClick={() => store.section("overview")}
            >
              ‹
            </button>
          )}
          <h2>{t(sections[section])}</h2>
          <button
            type="button"
            className="env-icon env-close"
            {...keyedIconProps(t(L.envClose), "escape")}
            disabled={state.saving}
            onClick={store.close}
          >
            ×
          </button>
        </header>
        <fieldset className="env-body" disabled={state.saving}>
          {state.loading && <output>{t(L.loading)}</output>}
          {draft && original && (
            <>
              {section === "overview" && (
                <div className="env-fields">
                  <label className="env-field">
                    <span>{t(L.envName)}</span>
                    <input
                      aria-label={t(L.envName)}
                      value={draft.name}
                      readOnly={original.is_default}
                      onChange={(event) => store.edit({ name: event.target.value })}
                    />
                    {original.is_default && <small>{t(L.envDefaultLocked)}</small>}
                  </label>
                  {draft.network.mode === "limited" && <p className="env-note">{t(L.envNetworkPending)}</p>}
                  <div className="env-rows">
                    {row(
                      "network",
                      [
                        t(draft.network.mode === "full" ? L.envFull : L.envLimited),
                        ...(draft.network.mode === "limited" ? draft.network.domains.filter(Boolean) : []),
                        ...(draft.network.mode === "limited" && draft.network.package_managers
                          ? [t(L.envPackages)]
                          : []),
                      ].join(" · "),
                    )}
                    {row(
                      "secrets",
                      draft.secrets
                        .map((secret) => secret.name)
                        .filter(Boolean)
                        .join(", ") || t(L.envNone),
                    )}
                    {row(
                      "script",
                      t(
                        draft.script !== null && draft.script !== ""
                          ? L.envScriptCustom
                          : state.derivedScript
                            ? L.envScriptDerived
                            : L.envScriptUnset,
                      ),
                    )}
                    {row(
                      "variables",
                      draft.variables
                        .map((variable) => variable.name)
                        .filter(Boolean)
                        .join(", ") || t(L.envNone),
                    )}
                  </div>
                </div>
              )}
              {section === "network" && <EnvironmentNetwork draft={draft} store={store} strings={strings} />}
              {(section === "secrets" || section === "variables") && (
                <EnvironmentValues draft={draft} store={store} strings={strings} secrets={section === "secrets"} />
              )}
              {section === "script" && <EnvironmentScript state={state} store={store} strings={strings} />}
            </>
          )}
          {state.error && (
            <p role="alert" className="env-error">
              {t(errorKeys[state.error])}
            </p>
          )}
          {!draft && !state.loading && (
            <button type="button" className="env-button" onClick={() => void store.retry()}>
              {t(L.retry)}
            </button>
          )}
        </fieldset>
        <footer className="env-actions">
          <DialogButton dialogKey="escape" className="env-button" disabled={state.saving} onClick={store.close}>
            {t(L.cancel)}
          </DialogButton>
          <DialogButton
            dialogKey="return"
            className="env-button env-primary"
            type="submit"
            disabled={!draft || state.saving}
          >
            {t(state.saving ? L.envSaving : L.envSave)}
          </DialogButton>
        </footer>
      </form>
    </Sheet>
  );
}
