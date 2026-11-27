// Settings > Developer: cmux API tokens (cmux platform /v1/tokens), as the bundled `cmux token list
// --json` reads them (SettingsDeveloperTokens in the app relays every gesture to the CLI). Personal
// tokens with New Token and Revoke; Team Tokens (CI, not tied to a person) and GitHub Actions (a
// repository signs in with GitHub's identity token, no stored secret) only for a person who may
// manage the team's. A new token is shown once, with Copy and the lines to paste; the host keeps no
// copy, and this card drops it on Done. Nothing changes without a click.
//
// Leo, 2026-11-25: "Should we be offering tokens/api keys for people to be accessing our stuff
// with?" and "Convienient beats all. Just make good ui for it so people flow."
import { useCallback, useEffect, useId, useState, type FormEvent } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import type {
  ApiToken,
  CreatedToken,
  DeveloperTokensRun,
  DeveloperTokensState,
  GithubTokenRule,
  TokenScope,
} from "../ops";
import { locale, t } from "../strings";
import {
  branchOf,
  capText,
  curlExample,
  DEFAULT_EXPIRATION,
  expiresText,
  exportLine,
  lastUsedText,
  refOf,
  repositoryOf,
  spendCapOf,
  TOKEN_EXPIRATIONS,
  TOKEN_SCOPES,
  workflowSnippet,
} from "../tokens";

const SELECT_CLASS =
  "box-border h-7 rounded-md border border-solid border-edge bg-transparent px-2 font-[inherit] text-control text-fg outline-none focus:border-accent-soft";

/** One gesture: whether it went through, and the token a create made (once). */
type Run = (
  run: Exclude<DeveloperTokensRun, { action: "refresh" }>,
) => Promise<{ ok: boolean; created: CreatedToken | null }>;

function expirationLabel(days: number | null): string {
  if (days === null) return t("settingsWindow.tokens.expires.never");
  if (days === 30) return t("settingsWindow.tokens.expires.30");
  if (days === 90) return t("settingsWindow.tokens.expires.90");
  return t("settingsWindow.tokens.expires.365");
}

function ScopeChips({ scopes }: { scopes: readonly TokenScope[] }) {
  return (
    <span className="tokens-chips" aria-label={t("settingsWindow.tokens.form.scopes")}>
      {TOKEN_SCOPES.filter((scope) => scopes.includes(scope)).map((scope) => (
        <span key={scope} className="tokens-chip" data-token-scope={scope}>
          {t(`settingsWindow.tokens.scope.${scope}`)}
        </span>
      ))}
    </span>
  );
}

/** Copy with a moment of "Copied" on the button. */
function CopyButton({ text, what, solid = false }: { text: string; what: string; solid?: boolean }) {
  const store = useStore();
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <Button
      type="button"
      variant={solid ? "solid" : "subtle"}
      className="button"
      data-tokens-copy={what}
      onClick={() => {
        void store.copy(text).then(() => setCopied(true));
      }}
    >
      {copied ? t("settingsWindow.tokens.copied") : t("settingsWindow.tokens.copy")}
    </Button>
  );
}

function CodeLine({ text, what }: { text: string; what: string }) {
  return (
    <div className="tokens-code-row">
      <pre className="tokens-code selectable" data-tokens-code={what}>
        {text}
      </pre>
      <CopyButton text={text} what={what} />
    </div>
  );
}

/** The token a create answered, once: Copy, the "won't be shown again" line, the lines to paste. */
function CreatedPanel({
  created,
  platform,
  onDone,
}: {
  created: CreatedToken;
  platform: string | null;
  onDone: () => void;
}) {
  const curl = curlExample(created.tokenInfo?.scopes ?? [], platform);
  return (
    <div className="accounts-form tokens-created" data-tokens-created="">
      <div className="row-title">{t("settingsWindow.tokens.created.title")}</div>
      <div className="row-help">{t("settingsWindow.tokens.created.once")}</div>
      <div className="tokens-code-row">
        <pre className="tokens-code tokens-secret selectable" data-tokens-secret="">
          {created.token}
        </pre>
        <CopyButton text={created.token} what="token" solid />
      </div>
      <div className="row-title tokens-subhead">{t("settingsWindow.tokens.created.shell")}</div>
      <CodeLine text={exportLine(created.token)} what="export" />
      {curl && (
        <>
          <div className="row-title tokens-subhead">{t("settingsWindow.tokens.created.curl")}</div>
          <CodeLine text={curl} what="curl" />
        </>
      )}
      <div className="accounts-buttons">
        <Button type="button" className="button" data-tokens-action="done" onClick={onDone}>
          {t("settingsWindow.tokens.done")}
        </Button>
      </div>
    </div>
  );
}

function ScopeChecks({ scopes, onChange }: { scopes: TokenScope[]; onChange: (scopes: TokenScope[]) => void }) {
  return (
    <fieldset className="tokens-fieldset">
      <legend className="row-title">{t("settingsWindow.tokens.form.scopes")}</legend>
      {TOKEN_SCOPES.map((scope) => (
        <label key={scope} className="tokens-check">
          <input
            type="checkbox"
            checked={scopes.includes(scope)}
            data-tokens-scope-check={scope}
            onChange={(event) =>
              onChange(
                event.target.checked
                  ? TOKEN_SCOPES.filter((one) => one === scope || scopes.includes(one))
                  : scopes.filter((one) => one !== scope),
              )
            }
          />
          <span>
            <span className="tokens-check-title">{t(`settingsWindow.tokens.scope.${scope}`)}</span>
            <span className="row-help">{t(`settingsWindow.tokens.scope.${scope}.help`)}</span>
          </span>
        </label>
      ))}
    </fieldset>
  );
}

/** New Token: name, scopes, expiration (a warning under No expiration) and an optional spend cap. */
function CreateForm({
  owner,
  busy,
  onRun,
  onCreated,
  onCancel,
}: {
  owner: "me" | "team";
  busy: boolean;
  onRun: Run;
  onCreated: (created: CreatedToken) => void;
  onCancel: () => void;
}) {
  const nameId = useId();
  const [name, setName] = useState("");
  const [scopes, setScopes] = useState<TokenScope[]>(["machines", "chats"]);
  const [expires, setExpires] = useState<number | null>(DEFAULT_EXPIRATION);
  const [cap, setCap] = useState("");
  const spendCap = spendCapOf(cap);
  const capInvalid = cap.trim().length > 0 && spendCap === null;
  const ready = name.trim().length > 0 && name.trim().length <= 64 && scopes.length > 0 && !capInvalid;
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!ready) return;
    const { created } = await onRun({
      action: "create",
      name: name.trim(),
      scopes,
      expiresInDays: expires,
      spendCapUsd: spendCap,
      owner,
    });
    if (created) onCreated(created);
  };
  return (
    <form className="accounts-form tokens-form" data-tokens-form={owner} onSubmit={(event) => void submit(event)}>
      <label className="tokens-field" htmlFor={nameId}>
        <span className="row-title">{t("settingsWindow.tokens.form.name")}</span>
        <Input
          id={nameId}
          className="field"
          spellCheck={false}
          maxLength={64}
          placeholder={
            owner === "team"
              ? t("settingsWindow.tokens.form.teamNamePlaceholder")
              : t("settingsWindow.tokens.form.namePlaceholder")
          }
          value={name}
          data-tokens-name=""
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <ScopeChecks scopes={scopes} onChange={setScopes} />
      <div className="tokens-row-fields">
        <label className="tokens-field">
          <span className="row-title">{t("settingsWindow.tokens.form.expiration")}</span>
          <select
            className={SELECT_CLASS}
            value={expires === null ? "never" : String(expires)}
            data-tokens-expiration=""
            onChange={(event) => setExpires(event.target.value === "never" ? null : Number(event.target.value))}
          >
            {TOKEN_EXPIRATIONS.map((days) => (
              <option key={String(days)} value={days === null ? "never" : String(days)}>
                {expirationLabel(days)}
              </option>
            ))}
          </select>
        </label>
        <label className="tokens-field">
          <span className="row-title">{t("settingsWindow.tokens.form.spendCap")}</span>
          <Input
            className="field tokens-cap"
            inputMode="decimal"
            placeholder={t("settingsWindow.tokens.form.spendCapPlaceholder")}
            value={cap}
            data-tokens-cap=""
            aria-invalid={capInvalid}
            onChange={(event) => setCap(event.target.value)}
          />
        </label>
      </div>
      {expires === null && (
        <div className="row-help tokens-warning" role="note" data-tokens-never-warning="">
          {t("settingsWindow.tokens.form.neverWarning")}
        </div>
      )}
      {scopes.length === 0 && <div className="row-help">{t("settingsWindow.tokens.form.pickScope")}</div>}
      {capInvalid && <div className="row-error">{t("settingsWindow.tokens.form.invalidSpendCap")}</div>}
      <div className="accounts-buttons">
        <Button type="submit" variant="solid" className="button" data-tokens-action="create" disabled={!ready || busy}>
          {t("settingsWindow.tokens.form.create")}
        </Button>
        <Button type="button" className="button" data-tokens-action="cancel" onClick={onCancel}>
          {t("settingsWindow.tokens.cancel")}
        </Button>
      </div>
    </form>
  );
}

/** A row with an inline "are you sure" for its one destructive button. */
function ConfirmRow({
  id,
  kind,
  title,
  details,
  chips,
  actionLabel,
  confirmTitle,
  confirmBody,
  busy,
  onConfirm,
}: {
  id: string;
  kind: "token" | "repository";
  title: string;
  details: string[];
  chips: readonly TokenScope[];
  actionLabel: string;
  confirmTitle: string;
  confirmBody: string;
  busy: boolean;
  onConfirm: () => void;
}) {
  const titleId = useId();
  const [confirming, setConfirming] = useState(false);
  return (
    <div className="row accounts-row" data-tokens-row={kind} data-tokens-id={id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title tokens-title" id={titleId}>
            <span>{title}</span>
            <ScopeChips scopes={chips} />
          </div>
          <div className="row-help selectable">{details.join(" · ")}</div>
        </div>
        {!confirming && (
          <span className="row-control">
            <Button
              danger
              variant="ghost"
              className="button"
              aria-describedby={titleId}
              data-tokens-action={kind === "token" ? "revoke" : "remove"}
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {actionLabel}
            </Button>
          </span>
        )}
      </div>
      {confirming && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" role="group" aria-label={confirmTitle} data-tokens-confirm="">
          <div className="row-title">{confirmTitle}</div>
          <div className="row-help">{confirmBody}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-tokens-action="confirm"
              disabled={busy}
              onClick={() => {
                setConfirming(false);
                onConfirm();
              }}
            >
              {actionLabel}
            </Button>
            <Button className="button" data-tokens-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsWindow.tokens.cancel")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function TokenRow({ token, now, busy, onRun }: { token: ApiToken; now: number; busy: boolean; onRun: Run }) {
  const lang = locale();
  const details = [
    token.display,
    token.source === "github" && token.repository ? t("settingsWindow.tokens.row.fromGithub", token.repository) : null,
    token.owner === "team" && token.createdByName ? t("settingsWindow.tokens.row.by", token.createdByName) : null,
    expiresText(token, now, lang),
    lastUsedText(token.lastUsedAt, now, lang),
    token.spendCapUsd ? capText(token.spendCapUsd, lang) : null,
  ].filter((part): part is string => !!part);
  return (
    <ConfirmRow
      id={token.id}
      kind="token"
      title={token.name}
      details={details}
      chips={token.scopes}
      actionLabel={t("settingsWindow.tokens.revoke")}
      confirmTitle={t("settingsWindow.tokens.revokeTitle", token.name)}
      confirmBody={t("settingsWindow.tokens.revokeBody")}
      busy={busy}
      onConfirm={() => void onRun({ action: "revoke", id: token.id })}
    />
  );
}

function RuleRow({ rule, now, busy, onRun }: { rule: GithubTokenRule; now: number; busy: boolean; onRun: Run }) {
  const branch = branchOf(rule.ref);
  const details = [
    branch ? t("settingsWindow.tokens.github.branchLabel", branch) : t("settingsWindow.tokens.github.anyBranch"),
    rule.environment ? t("settingsWindow.tokens.github.environmentLabel", rule.environment) : null,
    lastUsedText(rule.lastUsedAt, now, locale()),
  ].filter((part): part is string => !!part);
  return (
    <ConfirmRow
      id={rule.id}
      kind="repository"
      title={rule.repository}
      details={details}
      chips={rule.scopes}
      actionLabel={t("settingsWindow.tokens.github.remove")}
      confirmTitle={t("settingsWindow.tokens.github.removeTitle", rule.repository)}
      confirmBody={t("settingsWindow.tokens.github.removeBody")}
      busy={busy}
      onConfirm={() => void onRun({ action: "removeRepository", id: rule.id })}
    />
  );
}

function AllowRepositoryForm({ busy, onRun, onDone }: { busy: boolean; onRun: Run; onDone: () => void }) {
  const [repository, setRepository] = useState("");
  const [branch, setBranch] = useState("");
  const [environment, setEnvironment] = useState("");
  const [scopes, setScopes] = useState<TokenScope[]>(["machines", "chats"]);
  const parsed = repositoryOf(repository);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!parsed || scopes.length === 0) return;
    const ref = refOf(branch);
    const { ok } = await onRun({
      action: "allowRepository",
      repository: parsed,
      ...(ref ? { ref } : {}),
      ...(environment.trim() ? { environment: environment.trim() } : {}),
      scopes,
    });
    // A refused rule keeps the form, with what the person typed, under the refusal.
    if (ok) onDone();
  };
  return (
    <form className="accounts-form tokens-form" data-tokens-form="github" onSubmit={(event) => void submit(event)}>
      <label className="tokens-field">
        <span className="row-title">{t("settingsWindow.tokens.github.repository")}</span>
        <Input
          className="field"
          spellCheck={false}
          placeholder={t("settingsWindow.tokens.github.repositoryPlaceholder")}
          value={repository}
          data-tokens-repository=""
          onChange={(event) => setRepository(event.target.value)}
        />
      </label>
      {repository.trim() && !parsed && (
        <div className="row-error">{t("settingsWindow.tokens.github.badRepository")}</div>
      )}
      <div className="tokens-row-fields">
        <label className="tokens-field">
          <span className="row-title">{t("settingsWindow.tokens.github.branch")}</span>
          <Input
            className="field"
            spellCheck={false}
            placeholder={t("settingsWindow.tokens.github.anyBranch")}
            value={branch}
            data-tokens-branch=""
            onChange={(event) => setBranch(event.target.value)}
          />
        </label>
        <label className="tokens-field">
          <span className="row-title">{t("settingsWindow.tokens.github.environment")}</span>
          <Input
            className="field"
            spellCheck={false}
            placeholder={t("settingsWindow.tokens.github.anyEnvironment")}
            value={environment}
            data-tokens-environment=""
            onChange={(event) => setEnvironment(event.target.value)}
          />
        </label>
      </div>
      <ScopeChecks scopes={scopes} onChange={setScopes} />
      <div className="accounts-buttons">
        <Button
          type="submit"
          variant="solid"
          className="button"
          data-tokens-action="allow"
          disabled={!parsed || scopes.length === 0 || busy}
        >
          {t("settingsWindow.tokens.github.save")}
        </Button>
        <Button type="button" className="button" data-tokens-action="cancel" onClick={onDone}>
          {t("settingsWindow.tokens.cancel")}
        </Button>
      </div>
    </form>
  );
}

/** One list of tokens with its New button, its form and the token it just made. */
function TokenGroup({
  owner,
  tokens,
  now,
  busy,
  created,
  onCreated,
  onClearCreated,
  onRun,
}: {
  owner: "me" | "team";
  tokens: ApiToken[];
  now: number;
  busy: boolean;
  created: CreatedToken | null;
  onCreated: (created: CreatedToken) => void;
  onClearCreated: () => void;
  onRun: Run;
}) {
  const [creating, setCreating] = useState(false);
  const team = owner === "team";
  return (
    <section className="group" data-tokens-group={owner}>
      <div className="group-title">{team ? t("settingsWindow.tokens.team") : t("settingsWindow.tokens.personal")}</div>
      <div className="row-help tokens-lead">
        {team ? t("settingsWindow.tokens.teamHelp") : t("settingsWindow.tokens.personalHelp")}
      </div>
      {creating && (
        <CreateForm
          owner={owner}
          busy={busy}
          onRun={onRun}
          onCreated={(made) => {
            setCreating(false);
            onCreated(made);
          }}
          onCancel={() => setCreating(false)}
        />
      )}
      {tokens.length === 0 && !creating && !created && (
        <div className="row-help tokens-lead" data-tokens-empty={owner}>
          {team ? t("settingsWindow.tokens.teamEmpty") : t("settingsWindow.tokens.personalEmpty")}
        </div>
      )}
      {tokens.length > 0 && (
        <div className="rows">
          {tokens.map((token) => (
            <TokenRow key={token.id} token={token} now={now} busy={busy} onRun={onRun} />
          ))}
        </div>
      )}
      {!creating && (
        <div className="accounts-header hub-below">
          <Button
            className="button"
            data-tokens-action={team ? "newTeam" : "new"}
            disabled={busy}
            onClick={() => {
              onClearCreated();
              setCreating(true);
            }}
          >
            {team ? t("settingsWindow.tokens.newTeamToken") : t("settingsWindow.tokens.newToken")}
          </Button>
        </div>
      )}
    </section>
  );
}

function GithubGroup({
  rules,
  team,
  platform,
  now,
  busy,
  onRun,
}: {
  rules: GithubTokenRule[];
  team: string | null;
  platform: string | null;
  now: number;
  busy: boolean;
  onRun: Run;
}) {
  const [adding, setAdding] = useState(false);
  return (
    <section className="group" data-tokens-group="github">
      <div className="group-title">{t("settingsWindow.tokens.github.title")}</div>
      <div className="row-help tokens-lead">{t("settingsWindow.tokens.github.help")}</div>
      {adding && <AllowRepositoryForm busy={busy} onRun={onRun} onDone={() => setAdding(false)} />}
      {rules.length === 0 && !adding && (
        <div className="row-help tokens-lead" data-tokens-empty="github">
          {t("settingsWindow.tokens.github.empty")}
        </div>
      )}
      {rules.length > 0 && (
        <div className="rows">
          {rules.map((rule) => (
            <RuleRow key={rule.id} rule={rule} now={now} busy={busy} onRun={onRun} />
          ))}
        </div>
      )}
      {!adding && (
        <div className="accounts-header hub-below">
          <Button
            className="button"
            data-tokens-action="allowRepository"
            disabled={busy}
            onClick={() => setAdding(true)}
          >
            {t("settingsWindow.tokens.github.allow")}
          </Button>
        </div>
      )}
      <div className="row-title tokens-subhead">{t("settingsWindow.tokens.github.workflow")}</div>
      <div className="row-help">{t("settingsWindow.tokens.github.workflowHelp")}</div>
      <CodeLine text={workflowSnippet(team, platform)} what="workflow" />
    </section>
  );
}

export function DeveloperTokensCard() {
  const store = useStore();
  const [state, setState] = useState<DeveloperTokensState | null>(null);
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<CreatedToken | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const refresh = useCallback(async () => {
    const { state: next } = await store.runTokens({ action: "refresh" });
    setState(next);
    setNow(Date.now());
  }, [store]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  const run = useCallback<Run>(
    async (gesture) => {
      setBusy(true);
      const reply = await store.runTokens(gesture).catch(() => null);
      setBusy(false);
      if (!reply) return { ok: false, created: null };
      setState(reply.state);
      setNow(Date.now());
      return { ok: reply.ok, created: reply.created };
    },
    [store],
  );
  const listed = state && !state.problem ? state : null;
  const personal = listed?.tokens.filter((token) => token.owner === "me") ?? [];
  const team = listed?.tokens.filter((token) => token.owner === "team") ?? [];
  return (
    <div className="hub-card" data-card="developerTokens">
      <section className="group" data-tokens-group="header">
        <div className="group-title">{t("settingsWindow.tokens.title")}</div>
        <div className="row-help">{t("settingsWindow.tokens.help")}</div>
        {!state && (
          <div className="row-help hub-note" data-tokens-checking="">
            {t("settingsWindow.tokens.checking")}
          </div>
        )}
        {state?.problem === "unavailable" && (
          <div className="row-error hub-note" data-tokens-problem="unavailable">
            {t("settingsWindow.tokens.problem.unavailable")}
          </div>
        )}
        {state?.problem === "failed" && (
          <div
            className="row-error hub-note selectable"
            role="alert"
            data-tokens-problem={state.listError?.code ?? "failed"}
          >
            {state.listError?.message || t("settingsWindow.tokens.problem.failed")}
          </div>
        )}
        {state?.error && (
          <div className="row-error hub-note selectable" role="alert" data-tokens-error={state.error.code}>
            {state.error.message || t("settingsWindow.tokens.error.notFinished")}
          </div>
        )}
      </section>
      {created && <CreatedPanel created={created} platform={state?.platform ?? null} onDone={() => setCreated(null)} />}
      {listed && (
        <>
          <TokenGroup
            owner="me"
            tokens={personal}
            now={now}
            busy={busy}
            created={created}
            onCreated={setCreated}
            onClearCreated={() => setCreated(null)}
            onRun={run}
          />
          {listed.canManageTeamTokens && (
            <TokenGroup
              owner="team"
              tokens={team}
              now={now}
              busy={busy}
              created={created}
              onCreated={setCreated}
              onClearCreated={() => setCreated(null)}
              onRun={run}
            />
          )}
          {listed.canManageTeamTokens && listed.githubRules && (
            <GithubGroup
              rules={listed.githubRules}
              team={listed.team}
              platform={listed.platform}
              now={now}
              busy={busy}
              onRun={run}
            />
          )}
        </>
      )}
    </div>
  );
}
