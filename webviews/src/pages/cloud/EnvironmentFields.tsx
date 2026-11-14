import { useId, useRef, useState } from "react";
import type { Strings } from "../shared/i18n";
import { L } from "./strings";
import {
  DEFAULT_SECRET_HEADER,
  environmentConfig,
  fileFits,
  filePathValid,
  filesFit,
  imageId,
  imageName,
  imageOptions,
  type EnvironmentImage,
  repositoryValid,
  setupOutput,
  type CloudEnvironment,
  type FileDraft,
  type NetworkMode,
  type SetupStep,
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
  const original = store.getSnapshot().original;
  // Off only where the service keeps it (`environmentConfig`); an older one answers Full or Limited alone.
  const modes: NetworkMode[] =
    original && environmentConfig(original).off ? ["full", "limited", "off"] : ["full", "limited"];
  return (
    <div className="env-fields">
      <fieldset className="env-modes">
        <legend>{t(L.envNetwork)}</legend>
        {modes.map((mode) => (
          <label key={mode}>
            <input
              aria-label={t(networkLabels[mode])}
              type="radio"
              name="environment-network"
              checked={network.mode === mode}
              onChange={() => store.edit({ network: { ...network, mode } })}
            />
            {t(networkLabels[mode])}
          </label>
        ))}
      </fieldset>
      {network.mode === "off" && (
        <>
          <p className="env-note">{t(L.envOffNote)}</p>
          {/* Honest about today: the service refuses a chat start on Off (cloud_environment.network_unenforced). */}
          <p className="env-note">{t(L.envOffPending)}</p>
        </>
      )}
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

export const networkLabels: Record<NetworkMode, string> = { full: L.envFull, limited: L.envLimited, off: L.envOff };

/** The repository a machine clones, `owner/name`, and its branch (empty: the default branch). */
export function EnvironmentRepository({
  draft,
  store,
  strings,
}: {
  draft: EnvironmentDraft;
  store: EnvironmentStore;
  strings: Strings;
}) {
  const { t } = strings;
  const [editing, setEditing] = useState(false);
  const bad = !editing && !repositoryValid(draft.repo, draft.ref);
  return (
    <div className="env-fields">
      <div className="env-repository">
        <label className="env-field">
          <span>{t(L.envRepository)}</span>
          <input
            aria-label={t(L.envRepository)}
            aria-invalid={bad || undefined}
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            placeholder={t(L.envRepositoryPlaceholder)}
            value={draft.repo}
            onFocus={() => setEditing(true)}
            onBlur={() => setEditing(false)}
            onChange={(event) => store.edit({ repo: event.target.value })}
          />
        </label>
        <label className="env-field">
          <span>{t(L.envBranch)}</span>
          <input
            aria-label={t(L.envBranch)}
            aria-invalid={bad || undefined}
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            placeholder={t(L.envBranchPlaceholder)}
            value={draft.ref}
            onFocus={() => setEditing(true)}
            onBlur={() => setEditing(false)}
            onChange={(event) => store.edit({ ref: event.target.value })}
          />
        </label>
      </div>
      <div className="env-fold" data-open={bad || undefined}>
        <div className="env-fold-body">{bad && <small className="env-error">{t(L.envInvalidRepository)}</small>}</div>
      </div>
      <p className="env-note">{t(L.envRepositoryHint)}</p>
    </div>
  );
}

/** The base image, by name: the service's list when it gives one, else the stored image alone (today the
 *  service has one, `default`, so the picker shows that one option). */
export function EnvironmentImagePicker({
  draft,
  original,
  store,
  strings,
}: {
  draft: EnvironmentDraft;
  original: CloudEnvironment;
  store: EnvironmentStore;
  strings: Strings;
}) {
  const { t } = strings;
  const images = imageOptions(original);
  // A stored image the list no longer names stays listed, so the picker never shows another one picked.
  const ids = images.map(imageId);
  const stored = draft.image !== null && !ids.includes(draft.image) ? [draft.image] : [];
  const label = (image: EnvironmentImage) => (imageId(image) === "default" ? t(L.envImageDefault) : imageName(image));
  return (
    <label className="env-field">
      <span>{t(L.envImage)}</span>
      <select
        aria-label={t(L.envImage)}
        value={draft.image ?? ""}
        onChange={(event) => store.edit({ image: event.target.value || null })}
      >
        {draft.image === null && <option value="">{t(L.envImageDefault)}</option>}
        {[...images, ...stored].map((image) => (
          <option key={imageId(image)} value={imageId(image)}>
            {label(image)}
          </option>
        ))}
      </select>
      <small>{t(L.envImageHint)}</small>
    </label>
  );
}

/** Text files written to the machine before setup: a path and its contents per row. */
export function EnvironmentFiles({
  draft,
  store,
  strings,
}: {
  draft: EnvironmentDraft;
  store: EnvironmentStore;
  strings: Strings;
}) {
  const { t } = strings;
  const [editing, setEditing] = useState<string>();
  const set = (files: FileDraft[]) => store.edit({ files });
  const edit = (id: string | undefined, patch: Partial<FileDraft>) =>
    set(draft.files.map((file) => (file.id === id ? { ...file, ...patch } : file)));
  const tooMany = !filesFit(draft.files);
  return (
    <div className="env-fields">
      <p className="env-note">{t(L.envFilesNote)}</p>
      <div className="env-fold" data-open={tooMany || undefined}>
        <div className="env-fold-body">{tooMany && <small className="env-error">{t(L.envFilesTooLarge)}</small>}</div>
      </div>
      {draft.files.map((file, index) => {
        const repeated = draft.files.some((other) => other !== file && other.path.trim() === file.path.trim());
        const pathBad = editing !== file.id && file.path !== "" && (!filePathValid(file.path.trim()) || repeated);
        const sizeBad = !fileFits(file.content);
        const message = pathBad ? L.envInvalidFilePath : sizeBad ? L.envFileTooLarge : undefined;
        return (
          <div className="env-file-row" key={file.id ?? index}>
            <div className="env-file-head">
              <input
                aria-label={t(L.envFilePath)}
                aria-invalid={pathBad || undefined}
                autoComplete="off"
                autoCapitalize="off"
                spellCheck={false}
                placeholder={t(L.envFilePathPlaceholder)}
                value={file.path}
                onFocus={() => setEditing(file.id)}
                onBlur={() => setEditing(undefined)}
                onChange={(event) => edit(file.id, { path: event.target.value })}
              />
              <button
                type="button"
                className="env-icon"
                aria-label={`${t(L.envRemoveFile)} ${file.path}`}
                onClick={() => set(draft.files.filter((item) => item.id !== file.id))}
              >
                ×
              </button>
            </div>
            <textarea
              className="env-file-content"
              aria-label={`${t(L.envFileContent)} ${file.path}`}
              aria-invalid={sizeBad || undefined}
              rows={4}
              spellCheck={false}
              autoCapitalize="off"
              autoCorrect="off"
              wrap="off"
              value={file.content}
              onChange={(event) => edit(file.id, { content: event.target.value })}
            />
            <div className="env-fold" data-open={message ? true : undefined}>
              <div className="env-fold-body">{message && <small className="env-error">{t(message)}</small>}</div>
            </div>
          </div>
        );
      })}
      <button
        type="button"
        className="env-button env-add"
        onClick={() => set([...draft.files, { id: rowId(), path: "", content: "" }])}
      >
        {t(L.envAddFile)}
      </button>
    </div>
  );
}

const stepLabels: Record<string, string> = {
  machine: L.envStepMachine,
  repo: L.envStepRepo,
  files: L.envStepFiles,
  secrets: L.envSecrets,
  network: L.envNetwork,
  install: L.envStepInstall,
  verify: L.envStepVerify,
  maintenance: L.envMaintenance,
  snapshot: L.envStepSnapshot,
};
const stepStates: Record<SetupStep["state"], string> = {
  pending: L.envStepPending,
  running: L.envStepRunning,
  done: L.envStepDone,
  failed: L.envStepFailed,
  skipped: L.envStepSkipped,
};
const reasons: Record<string, string> = {
  first: L.envReasonFirst,
  setup_script: L.envReasonScript,
  script: L.envReasonScript,
  env_vars: L.envReasonVariables,
  variables: L.envReasonVariables,
  files: L.envReasonFiles,
  image: L.envReasonImage,
  repo: L.envReasonRepository,
  ref: L.envReasonRepository,
  repository: L.envReasonRepository,
  expired: L.envReasonExpired,
  refresh: L.envReasonExpired,
  inputs: L.envReasonInputs,
};

/** The last setup or maintenance run: the snapshot's state (cached, or rebuilding and why), each step, and the
 *  end of its log. Read only: the run is the service's, and this page changes nothing. */
export function EnvironmentOutput({ state, strings }: { state: EnvironmentState; strings: Strings }) {
  const { t } = strings;
  const { run, snapshot } = setupOutput(state.original, state.derived);
  if (!run && !snapshot)
    return (
      <div className="env-fields">
        <p className="env-note">{t(L.envOutputEmpty)}</p>
      </div>
    );
  const reason = snapshot?.reason ? (reasons[snapshot.reason] ?? L.envReasonInputs) : undefined;
  return (
    <div className="env-fields">
      {snapshot && (
        <div className="env-output-status" data-state={snapshot.state}>
          <span className="env-row-title">
            {t(
              snapshot.state === "cached"
                ? L.envSnapshotCached
                : snapshot.state === "rebuilding"
                  ? L.envSnapshotRebuilding
                  : L.envSnapshotNone,
            )}
          </span>
          {snapshot.state === "cached" && <span className="env-note">{t(L.envSnapshotCachedNote)}</span>}
          {snapshot.state !== "cached" && reason && <span className="env-note">{t(reason)}</span>}
        </div>
      )}
      {run && (
        <section className="env-run" aria-label={t(run.kind === "maintenance" ? L.envRunMaintenance : L.envRunSetup)}>
          <header className="env-run-heading">
            <span className="env-row-title">{t(run.kind === "maintenance" ? L.envRunMaintenance : L.envRunSetup)}</span>
            <span className={run.status === "failed" ? "env-error" : "env-note"} data-status={run.status}>
              {t(
                run.status === "running"
                  ? L.envRunRunning
                  : run.status === "failed"
                    ? L.envRunFailed
                    : L.envRunSucceeded,
              )}
            </span>
          </header>
          {run.steps.length > 0 && (
            <ol className="env-steps">
              {run.steps.map((step) => (
                <li key={step.id} className="env-step" data-state={step.state}>
                  <span className="env-step-name">{stepLabels[step.id] ? t(stepLabels[step.id]!) : step.id}</span>
                  {step.detail && <span className="env-row-detail env-step-detail">{step.detail}</span>}
                  <span className={step.state === "failed" ? "env-error" : "env-note"}>
                    {t(stepStates[step.state])}
                  </span>
                </li>
              ))}
            </ol>
          )}
          {run.error?.message && <p className="env-error">{run.error.message}</p>}
          {run.log_tail && (
            <div className="env-log">
              <span className="env-note">{t(L.envLogTail)}</span>
              <pre>{run.log_tail}</pre>
            </div>
          )}
        </section>
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

/** The setup script, or (`maintenance`) the maintenance script beside it: the same editor, with no repository
 *  suggestion for maintenance. */
export function EnvironmentScript({
  state,
  store,
  strings,
  maintenance = false,
}: {
  state: EnvironmentState;
  store: EnvironmentStore;
  strings: Strings;
  maintenance?: boolean;
}) {
  const { t } = strings;
  const script = maintenance ? (state.draft?.maintenance ?? "") : (state.draft?.script ?? state.derivedScript ?? "");
  const label = maintenance ? L.envMaintenance : L.envScript;
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
                if (file) void store.importScript(file, maintenance ? "maintenance" : "script");
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
            aria-label={t(label)}
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
              store.edit(maintenance ? { maintenance: event.target.value } : { script: event.target.value });
            }}
          />
        </div>
        <div className="env-editor-foot">{t(L.envFileLimit)}</div>
      </div>
      {!maintenance && state.deriving && <output className="env-note">{t(L.loading)}</output>}
      {!maintenance && state.deriveFailed && (
        <p role="alert" className="env-note">
          {t(L.envDeriveFailed)}{" "}
          <button type="button" className="env-link" onClick={() => void store.derive()}>
            {t(L.retry)}
          </button>
        </p>
      )}
      {!maintenance && state.derivedScript !== undefined && state.draft?.script !== null && (
        <button type="button" className="env-link" onClick={() => store.edit({ script: null })}>
          {t(L.envScriptReset)}
        </button>
      )}
      <p className="env-note">{t(maintenance ? L.envMaintenanceNote : L.envScriptNote)}</p>
    </div>
  );
}
