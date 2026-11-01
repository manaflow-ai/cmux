import { useRef, useState } from "react";
import type { Strings } from "../shared/i18n";
import { L } from "./strings";
import type { EnvironmentDraft, EnvironmentVariable } from "./environmentModel";
import type { EnvironmentState, EnvironmentStore } from "./environmentStore";

export function EnvironmentNetwork({
  draft,
  store,
  strings,
}: {
  draft: EnvironmentDraft;
  store: EnvironmentStore;
  strings: Strings;
}) {
  const { t } = strings;
  const { network } = draft;
  return (
    <div className="env-fields">
      <fieldset className="env-modes">
        <legend>{t(L.envNetwork)}</legend>
        {(["full", "limited"] as const).map((mode) => (
          <label key={mode}>
            <input
              aria-label={t(mode === "full" ? L.envFull : L.envLimited)}
              type="radio"
              name="environment-network"
              checked={network.mode === mode}
              onChange={() => store.edit({ network: { ...network, mode } })}
            />
            {t(mode === "full" ? L.envFull : L.envLimited)}
          </label>
        ))}
      </fieldset>
      {network.mode === "limited" && (
        <>
          <p className="env-note">{t(L.envNetworkPending)}</p>
          <label className="env-checkbox">
            <input
              aria-label={t(L.envPackages)}
              type="checkbox"
              checked={network.package_managers}
              onChange={(event) => store.edit({ network: { ...network, package_managers: event.target.checked } })}
            />
            {t(L.envPackages)}
          </label>
          <label className="env-field">
            <span>{t(L.envDomains)}</span>
            <textarea
              aria-label={t(L.envDomains)}
              rows={6}
              spellCheck={false}
              value={network.domains.join("\n")}
              onChange={(event) => store.edit({ network: { ...network, domains: event.target.value.split("\n") } })}
            />
            <small>{t(L.envDomainsHint)}</small>
          </label>
        </>
      )}
    </div>
  );
}

export function EnvironmentValues({
  draft,
  store,
  strings,
  secrets,
}: {
  draft: EnvironmentDraft;
  store: EnvironmentStore;
  strings: Strings;
  secrets: boolean;
}) {
  const { t } = strings;
  const rows = secrets ? draft.secrets : draft.variables;
  const set = (next: EnvironmentVariable[]) => store.edit(secrets ? { secrets: next } : { variables: next });
  const edit = (index: number, patch: Partial<EnvironmentVariable>) =>
    set(rows.map((row, at) => (at === index ? { ...row, ...patch } : row)));
  const existing = store.getSnapshot().original?.secrets ?? [];
  return (
    <div className="env-fields">
      {secrets && <p className="env-note">{t(L.envSecretNote)}</p>}
      {rows.map((row, index) => (
        <div className="env-value-row" key={index}>
          <input
            aria-label={t(secrets ? L.envSecretName : L.envVariableName)}
            autoComplete="off"
            spellCheck={false}
            value={row.name}
            readOnly={secrets && existing.some((item) => item.name === row.name)}
            onChange={(event) => edit(index, { name: event.target.value })}
          />
          <input
            aria-label={t(secrets ? L.envSecretValue : L.envValue)}
            autoComplete="off"
            type={secrets ? "password" : "text"}
            spellCheck={false}
            value={row.value}
            onChange={(event) => edit(index, { value: event.target.value })}
          />
          <button
            type="button"
            className="env-icon"
            aria-label={`${t(L.envRemove)} ${row.name}`}
            onClick={() => set(rows.filter((_, at) => at !== index))}
          >
            ×
          </button>
        </div>
      ))}
      <button type="button" className="env-button env-add" onClick={() => set([...rows, { name: "", value: "" }])}>
        {t(L.envAdd)}
      </button>
    </div>
  );
}

export function EnvironmentScript({
  state,
  store,
  strings,
}: {
  state: EnvironmentState;
  store: EnvironmentStore;
  strings: Strings;
}) {
  const { t } = strings;
  const script = state.draft?.script ?? state.derivedScript ?? "";
  const [copied, setCopied] = useState(false);
  const lines = useRef<HTMLPreElement>(null);
  return (
    <div className="env-fields">
      <div className="env-editor">
        <div className="env-editor-toolbar">
          <span className="env-language">Bash</span>
          <label className="env-file">
            <span>{t(L.envChooseFile)}</span>
            <input
              type="file"
              aria-label={t(L.envChooseFile)}
              onChange={(event) => {
                const file = event.target.files?.[0];
                if (file) void store.importScript(file);
                event.target.value = "";
              }}
            />
          </label>
          <button
            type="button"
            className="env-icon"
            aria-label={t(copied ? L.envCopied : L.envCopy)}
            title={t(copied ? L.envCopied : L.envCopy)}
            onClick={() => {
              if (!navigator.clipboard) return store.error("copy");
              void navigator.clipboard.writeText(script).then(
                () => setCopied(true),
                () => store.error("copy"),
              );
            }}
          >
            <svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" aria-hidden="true">
              <rect x="7" y="7" width="10" height="10" rx="2" />
              <path d="M13 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2" />
            </svg>
          </button>
        </div>
        <div className="env-code">
          <pre ref={lines} aria-hidden="true">
            {script
              .split("\n")
              .map((_, index) => index + 1)
              .join("\n")}
          </pre>
          <textarea
            aria-label={t(L.envScript)}
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
            wrap="off"
            value={script}
            onScroll={(event) => {
              if (lines.current) lines.current.scrollTop = event.currentTarget.scrollTop;
            }}
            onChange={(event) => {
              setCopied(false);
              store.edit({ script: event.target.value });
            }}
          />
        </div>
        <div className="env-editor-foot">{t(L.envFileLimit)}</div>
      </div>
      {state.deriving && <output className="env-note">{t(L.loading)}</output>}
      {state.deriveFailed && (
        <p role="alert" className="env-note">
          {t(L.envDeriveFailed)}{" "}
          <button type="button" className="env-link" onClick={() => void store.derive()}>
            {t(L.retry)}
          </button>
        </p>
      )}
      {state.derivedScript !== undefined && state.draft?.script !== null && (
        <button type="button" className="env-link" onClick={() => store.edit({ script: null })}>
          {t(L.envScriptReset)}
        </button>
      )}
      <p className="env-note">{t(L.envScriptNote)}</p>
    </div>
  );
}
