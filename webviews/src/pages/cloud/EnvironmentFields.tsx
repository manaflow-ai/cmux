import { useId, useRef, useState } from "react";
import type { Strings } from "../shared/i18n";
import { L } from "./strings";
import {
  DEFAULT_SECRET_HEADER,
  headerIssue,
  headerText,
  secretNeedsValue,
  secretRoutesSupported,
  hostsValid,
  rowId,
  secretHosts,
  type EnvironmentDraft,
  type EnvironmentSecret,
  type SecretDraft,
} from "./environmentModel";
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
  const rows: SecretDraft[] = secrets ? draft.secrets : draft.variables;
  const set = (next: SecretDraft[]) => store.edit(secrets ? { secrets: next } : { variables: next });
  // Rows go by their id, never their place: removing one above leaves every other row's state (its open header)
  // with it.
  const edit = (id: string | undefined, patch: Partial<SecretDraft>) =>
    set(rows.map((row) => (row.id === id ? { ...row, ...patch } : row)));
  const original = store.getSnapshot().original;
  const existing = original?.secrets ?? [];
  // Delivery only where the service keeps it; otherwise a host-only secret would be saved as a plain variable.
  const routes = secrets && original !== undefined && secretRoutesSupported(original);
  return (
    <div className="env-fields">
      {secrets && <p className="env-note">{t(L.envSecretNote)}</p>}
      {routes && <p className="env-note">{t(L.envSecretHostsNote)}</p>}
      {rows.map((row, index) => {
        const stored = secrets ? existing.find((item) => item.name === row.name) : undefined;
        const value = (
          <div className="env-value-row" key={row.id ?? index}>
            <input
              aria-label={t(secrets ? L.envSecretName : L.envVariableName)}
              autoComplete="off"
              spellCheck={false}
              value={row.name}
              readOnly={stored !== undefined}
              onChange={(event) => edit(row.id, { name: event.target.value })}
            />
            <input
              aria-label={t(secrets ? L.envSecretValue : L.envValue)}
              autoComplete="off"
              type={secrets ? "password" : "text"}
              spellCheck={false}
              value={row.value}
              aria-invalid={(routes && (!headerText(row.value) || secretNeedsValue(row, stored))) || undefined}
              onChange={(event) => edit(row.id, { value: event.target.value })}
            />
            <button
              type="button"
              className="env-icon"
              aria-label={`${t(L.envRemove)} ${row.name}`}
              onClick={() => set(rows.filter((item) => item.id !== row.id))}
            >
              ×
            </button>
          </div>
        );
        if (!routes) return value;
        return (
          <div className="env-secret" key={row.id ?? index}>
            {value}
            <SecretDelivery row={row} stored={stored} strings={strings} onChange={(patch) => edit(row.id, patch)} />
          </div>
        );
      })}
      <button
        type="button"
        className="env-button env-add"
        onClick={() => set([...rows, { id: rowId(), name: "", value: "" }])}
      >
        {t(L.envAdd)}
      </button>
    </div>
  );
}

/** One secret's "Sent to" hosts and its header (design/environment-sheet.md "Secret row"). Every secret has
 *  hosts (its value goes only there, never to the machine), so the header line is always under them,
 *  closed; its fields fold open under its disclosure by their own height, so the rows below move with
 *  it and nothing pops in. */
export function SecretDelivery({
  row,
  stored,
  strings,
  onChange,
}: {
  row: SecretDraft;
  stored?: EnvironmentSecret;
  strings: Strings;
  onChange(patch: Partial<SecretDraft>): void;
}) {
  const { t } = strings;
  const [editingHosts, setEditingHosts] = useState(false);
  const [headerOpen, setHeaderOpen] = useState(false);
  const header = row.header ?? DEFAULT_SECRET_HEADER;
  const hostsBad = !editingHosts && !hostsValid(row.hosts);
  // No host is invalid too, but not on a blank row just added (Save still refuses it) and not while typing.
  const hostless =
    !editingHosts && !secretHosts(row.hosts).length && (stored !== undefined || row.name !== "" || row.value !== "");
  const headerProblem = headerIssue(row.header);
  const headerBad = headerProblem !== undefined;
  const valueBad = !headerText(row.value);
  // A secret stored without hosts getting its first ones needs its value again (the platform can't move it
  // without).
  const retype = secretNeedsValue(row, stored);
  const message = hostsBad
    ? L.envInvalidHosts
    : hostless
      ? L.envSecretNoHosts
      : valueBad
        ? L.envInvalidValue
        : headerProblem === "route"
          ? L.envReservedHeader
          : headerProblem
            ? L.envInvalidHeader
            : retype
              ? L.envSecretRetype
              : undefined;
  const id = useId();
  return (
    <>
      <label className="env-secret-hosts">
        <span>{t(L.envSecretHosts)}</span>
        <input
          aria-label={t(L.envSecretHosts)}
          aria-invalid={hostsBad || hostless || undefined}
          aria-describedby={message ? `${id}-message` : undefined}
          autoComplete="off"
          autoCapitalize="off"
          spellCheck={false}
          placeholder={t(L.envSecretHostsPlaceholder)}
          value={row.hosts ?? ""}
          onFocus={() => setEditingHosts(true)}
          onBlur={() => setEditingHosts(false)}
          onChange={(event) => onChange({ hosts: event.target.value })}
        />
      </label>
      <button
        type="button"
        className="env-disclosure"
        aria-expanded={headerOpen}
        aria-controls={`${id}-header`}
        onClick={() => setHeaderOpen(!headerOpen)}
      >
        <span aria-hidden="true" className="env-disclosure-mark">
          ›
        </span>
        <span>{t(L.envSecretHeader)}</span>
        <span className="env-row-detail env-header-summary">{`${header.name}: ${header.format}`}</span>
      </button>
      <div id={`${id}-header`} className="env-fold" data-open={headerOpen || undefined} inert={!headerOpen}>
        <div className="env-fold-body">
          <div className="env-header-fields">
            <input
              aria-label={t(L.envSecretHeaderName)}
              aria-invalid={headerBad || undefined}
              autoComplete="off"
              spellCheck={false}
              value={header.name}
              onChange={(event) => onChange({ header: { ...header, name: event.target.value.toLowerCase() } })}
            />
            <input
              aria-label={t(L.envSecretHeaderFormat)}
              aria-invalid={headerBad || undefined}
              autoComplete="off"
              spellCheck={false}
              value={header.format}
              onChange={(event) => onChange({ header: { ...header, format: event.target.value } })}
            />
          </div>
          <small className="env-note">{t(L.envSecretHeaderHint)}</small>
        </div>
      </div>
      <div className="env-fold" data-open={message ? true : undefined}>
        <div className="env-fold-body">
          {message && (
            <small id={`${id}-message`} className="env-error">
              {t(message)}
            </small>
          )}
        </div>
      </div>
    </>
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
            <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" aria-hidden="true">
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
