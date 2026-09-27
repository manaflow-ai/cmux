"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { Tabs } from "@base-ui-components/react/tabs";
import { useFormatter, useNow, useTranslations } from "next-intl";
import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { useRouter } from "../../../../i18n/navigation";
import { Modal } from "../../components/modal";
import { CopyButton } from "../vault/copy-button";
import type {
  ClaudeAccountDescription,
  ClaudeUpstreamKind,
} from "../../../../services/coderouter/claudeUpstream";
import type { SubrouterAccount } from "../../../../services/subrouter/types";
import type { CodeRouterAccountSummary } from "../../../../services/coderouter/types";

/**
 * Every account the team routes through, in one list: the Claude upstream
 * accounts stored by the web app (Anthropic API key, Claude Code OAuth token,
 * Bedrock) and the shared accounts held by the hosted subrouter (Codex and
 * the CLI-added Claude accounts). Both kinds share one row shape and one add
 * panel, so a team never has to know which backend holds which credential.
 */
export type ClaudeAccountsState =
  | { readonly kind: "ok"; readonly accounts: readonly ClaudeAccountDescription[] }
  | { readonly kind: "error" };

/** Accounts `cr add` stores: Codex and OpenCode Go sign-ins routed by coderouter. */
export type NativeAccountsState =
  | { readonly kind: "ok"; readonly accounts: readonly CodeRouterAccountSummary[] }
  | { readonly kind: "error" };

export type SharedAccountsState =
  | { readonly kind: "ok"; readonly accounts: readonly SubrouterAccount[] }
  | { readonly kind: "migrationPending" }
  | { readonly kind: "notConfigured" }
  | { readonly kind: "error" };

type CoderouterApiKeySummary = {
  readonly id: string;
  readonly keyPrefix: string;
  readonly label: string;
  readonly createdAt: string;
  readonly lastUsedAt: string | null;
  readonly revokedAt: string | null;
  readonly usage: CoderouterApiKeyUsage | null;
};

type CoderouterApiKeyUsage = {
  readonly completions: number;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
  readonly pricedTokens: number;
  readonly unpricedTokens: number;
};

type IssuedCoderouterApiKey = Pick<
  CoderouterApiKeySummary,
  "id" | "keyPrefix" | "label" | "createdAt"
> & { readonly key: string };

type FormStatus = {
  readonly state: "idle" | "submitting" | "success" | "error";
  readonly message?: string;
};

const idleStatus: FormStatus = { state: "idle" };

/** Everything the add panel offers, in display order. */
type ApiKeyAddKind = "openai-apikey" | "openrouter-apikey";
type AddKind = ClaudeUpstreamKind | ApiKeyAddKind | "codex" | "opencode";
const ADD_KINDS: readonly AddKind[] = [
  "anthropic_api_key",
  "anthropic_oauth",
  "bedrock",
  "openai-apikey",
  "openrouter-apikey",
  "codex",
  "opencode",
];

const inputClass =
  "w-full border border-border bg-background px-2 py-1.5 font-mono text-xs text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground";
const buttonClass =
  "border border-border px-3 py-1.5 text-sm transition-colors hover:bg-foreground hover:text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";
const primaryButtonClass =
  "border border-foreground bg-foreground px-3 py-1.5 text-sm text-background transition-colors hover:bg-background hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";
const rowGridClass =
  "grid gap-2 px-3 py-2 text-sm md:grid-cols-[1.3fr_1fr_1.2fr_auto] md:items-center md:gap-3";
const API_KEY_REQUEST_TIMEOUT_MS = 10_000;

type Translator = ReturnType<typeof useTranslations<"dashboard.coderouterAccounts">>;

/** A team the viewer can move a native account into. */
export type CoderouterTransferTeam = { readonly id: string; readonly name: string };

export function CoderouterAccountsSection({
  teamId,
  teamName,
  viewerUserId,
  canManage,
  canManageApiKeys,
  transferTeams = [],
  claude,
  native,
  shared,
}: {
  readonly teamId: string;
  /** Selected team's display name, used in the transfer confirmation. */
  readonly teamName?: string;
  readonly viewerUserId?: string;
  readonly canManage: boolean;
  /** The viewer's other teams that can receive a native account. */
  readonly transferTeams?: readonly CoderouterTransferTeam[];
  readonly canManageApiKeys: boolean;
  readonly claude: ClaudeAccountsState;
  readonly native: NativeAccountsState;
  readonly shared: SharedAccountsState;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const claudeAccounts = claude.kind === "ok" ? claude.accounts : [];
  const nativeAccounts = native.kind === "ok" ? native.accounts : [];
  const sharedAccounts = shared.kind === "ok" ? shared.accounts : [];
  const total = claudeAccounts.length + nativeAccounts.length + sharedAccounts.length;
  // Field ids are per form, so switching the add tab never leaves two inputs
  // with one id.
  const partialFailure = claude.kind === "error" || native.kind === "error" || shared.kind === "error";
  // A moved account leaves this list on refresh, so its success notice lives
  // here rather than in the row that is about to unmount.
  const [transferNotice, setTransferNotice] = useState<string | null>(null);
  const transfer = canManage && transferTeams.length > 0
    ? { sourceTeamName: teamName ?? teamId, teams: transferTeams, onTransferred: setTransferNotice }
    : null;

  return (
    <section className="mb-4">
      <div className="mb-2 flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{t("title")}</h2>
          <p className="mt-1 max-w-2xl text-xs text-muted">{t("description")}</p>
        </div>
        <span className="font-mono text-[11px] text-muted">
          {t("accountsCount", { count: total })}
        </span>
      </div>

      {shared.kind === "notConfigured" && canManage ? (
        <Notice title={t("notConfiguredTitle")} body={t("notConfiguredBody")} />
      ) : null}
      {shared.kind === "migrationPending" ? (
        <Notice title={t("migrationPendingTitle")} body={t("migrationPendingBody")} />
      ) : null}
      {partialFailure ? (
        <Notice title={t("loadErrorTitle")} body={t("loadErrorBody")} />
      ) : null}
      {transferNotice ? (
        <p role="status" className="mb-2 border border-border p-3 text-xs">{transferNotice}</p>
      ) : null}

      {total === 0 ? (
        partialFailure ? null : (
          <div className="border border-border p-3">
            <div className="text-sm font-medium">{t("emptyTitle")}</div>
            <p className="mt-1 text-xs text-muted">{t("emptyBody")}</p>
          </div>
        )
      ) : (
        <div className="border border-border">
          <div className="hidden grid-cols-[1.3fr_1fr_1.2fr_auto] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
            <div>{t("providerColumn")}</div>
            <div>{t("labelColumn")}</div>
            <div>{t("statusColumn")}</div>
            <div className="text-right">{canManage ? t("actionsColumn") : ""}</div>
          </div>
          <ul className="divide-y divide-border">
            {claudeAccounts.map((account) => (
              <ClaudeAccountRow
                key={`claude:${account.id}`}
                teamId={teamId}
                viewerUserId={viewerUserId}
                account={account}
                canManage={canManage}
              />
            ))}
            {nativeAccounts.map((account) => (
              <NativeAccountRow
                key={`native:${account.id}`}
                teamId={teamId}
                viewerUserId={viewerUserId}
                account={account}
                canManage={canManage}
                transfer={transfer}
              />
            ))}
            {sharedAccounts.map((account) => (
              <SharedAccountRow
                key={`shared:${account.id}`}
                teamId={teamId}
                account={account}
                canManage={canManage}
              />
            ))}
          </ul>
        </div>
      )}

      {canManage ? <><p className="mt-2 text-xs text-muted">{t("privateImportHint")}</p><AddAccountPanel teamId={teamId} /></> : null}
      <CoderouterApiKeysSection teamId={teamId} canManage={canManageApiKeys} />
    </section>
  );
}

function CoderouterApiKeysSection({
  teamId,
  canManage,
}: {
  readonly teamId: string;
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const format = useFormatter();
  const now = useNow();
  const compactNumber = new Intl.NumberFormat(undefined, {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  const currency = new Intl.NumberFormat(undefined, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
  const [keys, setKeys] = useState<readonly CoderouterApiKeySummary[] | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<FormStatus>(idleStatus);
  const [issued, setIssued] = useState<IssuedCoderouterApiKey | null>(null);
  const [keysTeamId, setKeysTeamId] = useState(teamId);
  const [issuedTeamId, setIssuedTeamId] = useState(teamId);
  const requestGeneration = useRef(0);
  const activeRequest = useRef<AbortController | null>(null);
  const currentTeamId = useRef(teamId);

  const fetchKeys = useCallback(async (signal?: AbortSignal): Promise<readonly CoderouterApiKeySummary[]> => {
    const requestSignal = signal
      ? AbortSignal.any([signal, AbortSignal.timeout(API_KEY_REQUEST_TIMEOUT_MS)])
      : AbortSignal.timeout(API_KEY_REQUEST_TIMEOUT_MS);
    const response = await fetch("/api/coderouter/api-keys", {
      headers: { "x-cmux-team-id": teamId },
      cache: "no-store",
      signal: requestSignal,
    });
    if (!response.ok) throw new Error("api key list failed");
    const body = await response.json() as { keys?: CoderouterApiKeySummary[] };
    if (!Array.isArray(body.keys)) throw new Error("api key list malformed");
    return body.keys;
  }, [teamId]);

  const load = useCallback(async (expectedTeamId = teamId) => {
    if (expectedTeamId !== currentTeamId.current || expectedTeamId !== teamId) return;
    activeRequest.current?.abort();
    const controller = new AbortController();
    activeRequest.current = controller;
    const generation = ++requestGeneration.current;
    setLoading(true);
    setLoadError(false);
    try {
      const nextKeys = await fetchKeys(controller.signal);
      if (generation !== requestGeneration.current) return;
      setKeys(nextKeys);
      setKeysTeamId(teamId);
    } catch {
      if (generation !== requestGeneration.current) return;
      setLoadError(true);
    } finally {
      if (activeRequest.current === controller) activeRequest.current = null;
      if (generation !== requestGeneration.current) return;
      setLoading(false);
    }
  }, [fetchKeys, teamId]);

  useEffect(() => {
    // The render guard below keeps old team data out of the UI while this
    // request is in flight. The old request is also aborted before starting it.
    activeRequest.current?.abort();
    currentTeamId.current = teamId;
    const controller = new AbortController();
    activeRequest.current = controller;
    const generation = ++requestGeneration.current;
    void fetchKeys(controller.signal)
      .then((nextKeys) => {
        if (generation !== requestGeneration.current) return;
        setIssued(null);
        setIssuedTeamId(teamId);
        setKeys(nextKeys);
        setKeysTeamId(teamId);
        setLoadError(false);
        setLoading(false);
      })
      .catch(() => {
        if (generation !== requestGeneration.current) return;
        setIssued(null);
        setIssuedTeamId(teamId);
        setKeys(null);
        setKeysTeamId(teamId);
        setLoadError(true);
        setLoading(false);
      })
      .finally(() => {
        if (activeRequest.current === controller) activeRequest.current = null;
      });
    return () => {
      controller.abort();
      requestGeneration.current += 1;
    };
  }, [fetchKeys, teamId]);

  const teamSwitching = keysTeamId !== teamId;
  const visibleKeys = keysTeamId === teamId ? keys : null;
  const visibleIssued = !teamSwitching &&
    issuedTeamId === teamId &&
    issued;

  const create = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status.state === "submitting") return;
    const form = event.currentTarget;
    const label = String(new FormData(form).get("apiKeyLabel") ?? "").trim();
    setStatus({ state: "submitting" });
    try {
      const response = await fetch("/api/coderouter/api-keys", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cmux-team-id": teamId },
        body: JSON.stringify({ label }),
        signal: AbortSignal.timeout(API_KEY_REQUEST_TIMEOUT_MS),
      });
      if (!response.ok) {
        setStatus({ state: "error", message: response.status === 403 ? t("teamAccessError") : t("apiKeyCreateError") });
        return;
      }
      const created = await response.json() as IssuedCoderouterApiKey;
      if (!created.key || !created.id) throw new Error("api key response malformed");
      form.reset();
      setIssued(created);
      setIssuedTeamId(teamId);
      setStatus(idleStatus);
      await load(teamId);
    } catch {
      setStatus({ state: "error", message: t("apiKeyCreateError") });
    }
  };

  return (
    <section className="mt-4 border-t border-border pt-4">
      <div className="mb-2 flex flex-wrap items-end justify-between gap-2">
        <div>
          <h3 className="text-sm font-medium">{t("apiKeysTitle")}</h3>
          <p className="mt-1 max-w-2xl text-xs text-muted">{t("apiKeysDescription")}</p>
        </div>
        {visibleKeys ? <span className="font-mono text-[11px] text-muted">{t("apiKeysCount", { count: visibleKeys.length })}</span> : null}
      </div>

      {visibleIssued ? (
        <div className="mb-2 border border-foreground p-3">
          <div className="text-sm font-medium">{t("apiKeySecretTitle")}</div>
          <p className="mt-1 text-xs text-muted">{t("apiKeySecretBody")}</p>
          <div className="mt-2 flex flex-wrap items-center justify-between gap-2 border border-border px-3 py-2">
            <code className="min-w-0 break-all font-mono text-xs text-foreground">{visibleIssued.key}</code>
            <CopyButton value={visibleIssued.key} label={t("apiKeyCopy")} copiedLabel={t("apiKeyCopied")} />
          </div>
        </div>
      ) : null}

      {(loading || teamSwitching) && !visibleKeys ? <p className="border border-border p-3 text-xs text-muted">{t("apiKeysLoading")}</p> : null}
      {loadError && !teamSwitching ? (
        <div className="flex flex-wrap items-center justify-between gap-2 border border-border p-3 text-xs">
          <span>{t("apiKeysLoadError")}</span>
          <button type="button" className={buttonClass} onClick={() => void load()} disabled={loading}>{t("apiKeysRetry")}</button>
        </div>
      ) : null}
      {visibleKeys && visibleKeys.length === 0 ? <p className="border border-border p-3 text-xs text-muted">{t("apiKeysEmptyBody")}</p> : null}
      {visibleKeys && visibleKeys.length > 0 ? (
        <div className="border border-border">
          <div className="hidden grid-cols-[1.1fr_1fr_1.3fr_auto] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
            <div>{t("apiKeyPrefixColumn")}</div>
            <div>{t("labelColumn")}</div>
            <div>{t("apiKeyStatusColumn")}</div>
            <div className="text-right">{canManage ? t("actionsColumn") : ""}</div>
          </div>
          <ul className="divide-y divide-border">
            {[...visibleKeys].reverse().map((key) => {
              const created = new Date(key.createdAt);
              const lastUsed = key.lastUsedAt ? new Date(key.lastUsedAt) : null;
              const statusText = key.revokedAt ? t("apiKeyRevoked") : t("stateActive");
              const statusDetail = lastUsed
                ? t("apiKeyLastUsed", { at: format.relativeTime(lastUsed, now) })
                : t("neverUsed");
              const usageDetail = key.usage
                ? t("apiKeyUsageDetail", {
                  completions: compactNumber.format(key.usage.completions),
                  tokens: compactNumber.format(key.usage.totalTokens),
                  input: compactNumber.format(key.usage.inputTokens),
                  output: compactNumber.format(key.usage.outputTokens),
                  value: currency.format(key.usage.apiEquivalentUsd),
                })
                : t("apiKeyUsageUnavailable");
              return (
                <li key={key.id} className="grid gap-2 px-3 py-2 text-sm md:grid-cols-[1.1fr_1fr_1.3fr_auto] md:items-center md:gap-3">
                  <div className="min-w-0">
                    <div className="mb-1 text-xs text-muted md:hidden">{t("apiKeyPrefixColumn")}</div>
                    <code className="font-mono text-xs">{key.keyPrefix}</code>
                  </div>
                  <div className="min-w-0 truncate text-muted">
                    <div className="mb-1 text-xs text-muted md:hidden">{t("labelColumn")}</div>
                    {key.label || t("unlabeledAccount")}
                  </div>
                  <div className="min-w-0 text-xs">
                    <div className="mb-1 text-muted md:hidden">{t("apiKeyStatusColumn")}</div>
                    <div className={key.revokedAt ? "text-muted" : "text-foreground"}>{statusText}</div>
                    <div className="mt-0.5 text-muted">{t("apiKeyCreatedAt", { at: format.dateTime(created, { dateStyle: "medium" }) })} · {statusDetail}</div>
                    <div className="mt-0.5 text-muted">{usageDetail}</div>
                  </div>
                  <div className="text-right">{canManage && !key.revokedAt ? <ApiKeyRevokeAction teamId={teamId} keyId={key.id} onRevoked={() => void load(teamId)} /> : null}</div>
                </li>
              );
            })}
          </ul>
        </div>
      ) : null}

      {canManage ? (
        <form onSubmit={create} className="mt-3 flex flex-wrap items-end gap-2">
          <label className="min-w-56 flex-1">
            <span className="mb-1 block text-xs text-muted">{t("labelField")}</span>
            <input name="apiKeyLabel" required maxLength={80} autoComplete="off" className={inputClass} placeholder={t("apiKeyLabelPlaceholder")} />
          </label>
          <button type="submit" disabled={status.state === "submitting"} className={primaryButtonClass}>
            {status.state === "submitting" ? t("creatingApiKeyAction") : t("createApiKeyAction")}
          </button>
          {status.state === "error" && status.message ? <span role="alert" className="w-full text-xs text-foreground">{status.message}</span> : null}
        </form>
      ) : null}
    </section>
  );
}

function ApiKeyRevokeAction({
  teamId,
  keyId,
  onRevoked,
}: {
  readonly teamId: string;
  readonly keyId: string;
  readonly onRevoked: () => void;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const [pending, setPending] = useState(false);
  const [open, setOpen] = useState(false);
  const [error, setError] = useState(false);
  const revoke = async () => {
    if (pending) return;
    setPending(true);
    setError(false);
    try {
      const response = await fetch(`/api/coderouter/api-keys/${encodeURIComponent(keyId)}`, {
        method: "DELETE",
        headers: { "x-cmux-team-id": teamId },
        signal: AbortSignal.timeout(API_KEY_REQUEST_TIMEOUT_MS),
      });
      if (!response.ok) {
        setError(true);
        return;
      }
      setOpen(false);
      onRevoked();
    } catch {
      setError(true);
    } finally {
      setPending(false);
    }
  };
  return (
    <div>
      <button type="button" className={buttonClass} onClick={() => setOpen(true)} disabled={pending}>
        {pending ? t("revokingApiKeyAction") : t("revokeApiKeyAction")}
      </button>
      {error ? <p role="alert" className="mt-1 text-xs text-foreground">{t("apiKeyRevokeError")}</p> : null}
      <Modal open={open} onOpenChange={setOpen}>
        <Dialog.Title className="text-left text-sm font-medium">{t("revokeApiKeyConfirmTitle")}</Dialog.Title>
        <Dialog.Description className="mt-2 text-left text-xs text-muted">{t("revokeApiKeyConfirmBody")}</Dialog.Description>
        <div className="mt-5 flex justify-end gap-2">
          <Dialog.Close className={buttonClass}>{t("cancelAction")}</Dialog.Close>
          <button type="button" onClick={() => void revoke()} className={primaryButtonClass}>{t("revokeApiKeyAction")}</button>
        </div>
      </Modal>
    </div>
  );
}

function Notice({ title, body }: { readonly title: string; readonly body: string }) {
  return (
    <div className="mb-2 border border-border p-3">
      <div className="text-sm font-medium">{title}</div>
      <p className="mt-1 text-xs text-muted">{body}</p>
    </div>
  );
}

function ClaudeAccountRow({
  teamId,
  viewerUserId,
  account,
  canManage,
}: {
  readonly teamId: string;
  readonly viewerUserId?: string;
  readonly account: ClaudeAccountDescription;
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const format = useFormatter();
  const now = useNow();
  const cooling = account.cooldownUntil !== null &&
    new Date(account.cooldownUntil).getTime() > now.getTime();
  const health = account.state === "disabled"
    ? t("stateDisabled")
    : cooling
      ? t("coolingDown", {
        until: format.dateTime(new Date(account.cooldownUntil!), { timeStyle: "short" }),
      })
      : t("stateActive");
  const usage = account.lastUsedAt
    ? t("lastUsed", { at: format.relativeTime(new Date(account.lastUsedAt), now) })
    : t("neverUsed");
  return (
    <AccountRowFrame
      provider={claudeKindLabel(account.kind, t)}
      detail={canManage ? `${account.identifier}${account.region ? ` · ${account.region}` : ""}` : null}
      label={account.label}
      status={health}
      statusDetail={
        account.lastFailureCode
          ? `${usage} · ${t("lastFailure", { code: account.lastFailureCode })}`
          : usage
      }
      dimmed={account.state === "disabled"}
      actions={canManage ? <div className="flex flex-wrap gap-2">{(!account.createdBy || account.createdBy === viewerUserId) ? <AccountSharing teamId={teamId} accountId={account.id} family="claude" visibility={account.visibility ?? "team"} /> : null}<ClaudeAccountActions teamId={teamId} account={account} /></div> : null}
      t={t}
    />
  );
}

type NativeTransferOptions = {
  readonly sourceTeamName: string;
  readonly teams: readonly CoderouterTransferTeam[];
  readonly onTransferred: (message: string) => void;
};

function NativeAccountRow({
  teamId,
  viewerUserId,
  account,
  canManage,
  transfer,
}: {
  readonly teamId: string;
  readonly viewerUserId?: string;
  readonly account: CodeRouterAccountSummary;
  readonly canManage: boolean;
  readonly transfer: NativeTransferOptions | null;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const format = useFormatter();
  const now = useNow();
  const cooling = account.cooldownUntil !== null &&
    new Date(account.cooldownUntil).getTime() > now.getTime();
  const status = account.state === "broken"
    ? t("stateBroken")
    : account.state === "expired"
      ? t("stateExpired")
      : account.state === "refreshing"
        ? t("stateRefreshing")
        : cooling
        ? t("coolingDown", {
          until: format.dateTime(new Date(account.cooldownUntil!), { timeStyle: "short" }),
        })
        : t("stateActive");
  const sessions = t("activeSessions", { count: account.activeSessions });
  return (
    <AccountRowFrame
      provider={nativeKindLabel(account.provider, t)}
      detail={canManage ? account.providerAccountId : null}
      label={account.label}
      status={status}
      statusDetail={
        account.lastFailureCode && account.state !== "active" && account.state !== "refreshing"
          ? `${sessions} · ${t("lastFailure", { code: account.lastFailureCode })}`
          : sessions
      }
      dimmed={account.state === "broken" || account.state === "expired"}
      actions={canManage ? <div className="flex flex-wrap gap-2">{(!account.createdBy || account.createdBy === viewerUserId) ? <AccountSharing teamId={teamId} accountId={account.id} family="native" visibility={account.visibility ?? "team"} /> : null}{transfer ? <NativeAccountTransfer teamId={teamId} accountId={account.id} accountLabel={account.label || t("unlabeledAccount")} {...transfer} /> : null}<NativeAccountActions teamId={teamId} accountId={account.id} /></div> : null}
      t={t}
    />
  );
}

function AccountSharing({ teamId, accountId, family, visibility }: {
  readonly teamId: string;
  readonly accountId: string;
  readonly family: "native" | "claude";
  readonly visibility: "private" | "team";
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);
  async function updateSharing() {
    if (pending) return;
    setPending(true);
    setError(false);
    try {
      const response = await fetch(`/api/coderouter/accounts/${encodeURIComponent(accountId)}/sharing`, {
        method: "PATCH", headers: { "content-type": "application/json", "x-cmux-team-id": teamId },
        body: JSON.stringify({ family, visibility: visibility === "private" ? "team" : "private" }),
      });
      if (!response.ok) { setError(true); return; }
      router.refresh();
    } catch { setError(true); } finally { setPending(false); }
  }
  return <div>
    <button type="button" className={buttonClass} disabled={pending} onClick={updateSharing}>
      {visibility === "private" ? t("shareWithTeam") : t("makePrivate")}
    </button>
    {error ? <p role="alert" className="text-xs text-red-500">{t("updateError")}</p> : null}
  </div>;
}

function NativeAccountActions({
  teamId,
  accountId,
}: {
  readonly teamId: string;
  readonly accountId: string;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);
  const [confirmOpen, setConfirmOpen] = useState(false);

  const remove = async () => {
    if (status.state === "submitting") return;
    setConfirmOpen(false);
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/coderouter/accounts/${encodeURIComponent(accountId)}`,
        { method: "DELETE", headers: { "x-cmux-team-id": teamId } },
      );
      if (!response.ok && response.status !== 404) {
        setStatus({ state: "error", message: errorMessageForStatus(response.status, t, t("removeError")) });
        return;
      }
      setStatus(idleStatus);
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("removeError") });
    }
  };

  return (
    <RowActions
      status={status}
      confirmOpen={confirmOpen}
      setConfirmOpen={setConfirmOpen}
      onConfirm={remove}
      confirmTitle={t("removeConfirmTitle")}
      confirmBody={t("removeNativeConfirmBody")}
      t={t}
    />
  );
}

export type TransferRequestResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly status: number | null };

/** Moves one native account from `teamId` to `destinationTeamId`. */
export async function requestNativeAccountTransfer(
  input: { readonly teamId: string; readonly accountId: string; readonly destinationTeamId: string },
  send: typeof fetch = fetch,
): Promise<TransferRequestResult> {
  try {
    const response = await send(`/api/coderouter/accounts/${encodeURIComponent(input.accountId)}/transfer`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-cmux-team-id": input.teamId },
      body: JSON.stringify({ destinationTeamId: input.destinationTeamId }),
      signal: AbortSignal.timeout(API_KEY_REQUEST_TIMEOUT_MS),
    });
    return response.ok ? { ok: true } : { ok: false, status: response.status };
  } catch {
    return { ok: false, status: null };
  }
}

const TRANSFER_ERROR_KEYS = {
  400: "validationError",
  403: "transferForbiddenError",
  404: "transferNotFoundError",
  409: "transferConflictError",
  503: "transferUnavailableError",
} as const;

function transferErrorMessage(status: number | null, t: Translator): string {
  const key = status === null ? undefined : TRANSFER_ERROR_KEYS[status as keyof typeof TRANSFER_ERROR_KEYS];
  return t(key ?? "transferError");
}

function NativeAccountTransfer({
  teamId,
  accountId,
  accountLabel,
  sourceTeamName,
  teams,
  onTransferred,
}: NativeTransferOptions & {
  readonly teamId: string;
  readonly accountId: string;
  readonly accountLabel: string;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<"choose" | "confirm">("choose");
  const [destinationId, setDestinationId] = useState(teams[0]?.id ?? "");
  const [status, setStatus] = useState<FormStatus>(idleStatus);
  const destination = teams.find((team) => team.id === destinationId) ?? teams[0];

  const openDialog = () => {
    setStep("choose");
    setDestinationId(teams[0]?.id ?? "");
    setStatus(idleStatus);
    setOpen(true);
  };

  const confirm = async () => {
    if (status.state === "submitting" || !destination) return;
    setStatus({ state: "submitting" });
    const result = await requestNativeAccountTransfer({ teamId, accountId, destinationTeamId: destination.id });
    if (!result.ok) {
      setStatus({ state: "error", message: transferErrorMessage(result.status, t) });
      return;
    }
    setOpen(false);
    setStatus(idleStatus);
    onTransferred(t("transferSuccess", { account: accountLabel, destination: destination.name }));
    router.refresh();
  };

  const submitting = status.state === "submitting";
  return (
    <div>
      <button type="button" className={buttonClass} onClick={openDialog} disabled={submitting}>
        {submitting ? t("transferringAction") : t("transferAction")}
      </button>
      <Modal open={open} onOpenChange={(next) => { if (!submitting) setOpen(next); }}>
        {step === "choose" ? (
          <>
            <Dialog.Title className="text-left text-sm font-medium">{t("transferDialogTitle")}</Dialog.Title>
            <Dialog.Description className="mt-2 text-left text-xs text-muted">
              {t("transferChooseBody", { account: accountLabel, source: sourceTeamName })}
            </Dialog.Description>
            <label className="mt-3 block text-left">
              <span className="mb-1 block text-xs text-muted">{t("transferDestinationLabel")}</span>
              <select
                value={destination?.id ?? ""}
                onChange={(event) => setDestinationId(event.target.value)}
                className={inputClass}
              >
                {teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}
              </select>
            </label>
            <div className="mt-5 flex justify-end gap-2">
              <Dialog.Close className={buttonClass}>{t("cancelAction")}</Dialog.Close>
              <button type="button" className={primaryButtonClass} disabled={!destination} onClick={() => setStep("confirm")}>
                {t("continueAction")}
              </button>
            </div>
          </>
        ) : (
          <>
            <Dialog.Title className="text-left text-sm font-medium">{t("transferConfirmTitle", { account: accountLabel })}</Dialog.Title>
            <Dialog.Description className="mt-2 text-left text-xs text-muted">
              {t("transferConfirmBody", { account: accountLabel, source: sourceTeamName, destination: destination?.name ?? "" })}
            </Dialog.Description>
            {status.state === "error" && status.message ? (
              <p role="alert" className="mt-2 text-left text-xs text-foreground">{status.message}</p>
            ) : null}
            <div className="mt-5 flex justify-end gap-2">
              <button type="button" className={buttonClass} disabled={submitting} onClick={() => { setStatus(idleStatus); setStep("choose"); }}>
                {t("backAction")}
              </button>
              <Dialog.Close className={buttonClass} disabled={submitting}>{t("cancelAction")}</Dialog.Close>
              <button type="button" className={primaryButtonClass} disabled={submitting} onClick={() => void confirm()}>
                {submitting ? t("transferringAction") : t("transferConfirmAction")}
              </button>
            </div>
          </>
        )}
      </Modal>
    </div>
  );
}

function SharedAccountRow({
  teamId,
  account,
  canManage,
}: {
  readonly teamId: string;
  readonly account: SubrouterAccount;
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const format = useFormatter();
  const created = account.createdAt ? new Date(account.createdAt) : null;
  const createdText = created && !Number.isNaN(created.getTime())
    ? t("createdAt", { at: format.dateTime(created, { dateStyle: "medium" }) })
    : null;
  const healthy = account.health?.ok !== false;
  return (
    <AccountRowFrame
      provider={sharedKindLabel(account.kind, t)}
      detail={null}
      label={account.label ?? null}
      status={healthy ? t("stateActive") : (account.health?.message || t("stateUnhealthy"))}
      statusDetail={createdText}
      dimmed={!healthy}
      actions={canManage ? <SharedAccountActions teamId={teamId} accountId={account.id} /> : null}
      t={t}
    />
  );
}

function AccountRowFrame({
  provider,
  detail,
  label,
  status,
  statusDetail,
  dimmed,
  actions,
  t,
}: {
  readonly provider: string;
  readonly detail: string | null;
  readonly label: string | null;
  readonly status: string;
  readonly statusDetail: string | null;
  readonly dimmed: boolean;
  readonly actions: ReactNode;
  readonly t: Translator;
}) {
  return (
    <li className={rowGridClass}>
      <div className="min-w-0">
        <div className="mb-1 text-xs text-muted md:hidden">{t("providerColumn")}</div>
        <div>{provider}</div>
        {detail ? (
          <div className="mt-0.5 truncate font-mono text-xs text-muted">{detail}</div>
        ) : null}
      </div>
      <div className="min-w-0 truncate text-muted">
        <div className="mb-1 text-xs text-muted md:hidden">{t("labelColumn")}</div>
        {label || t("unlabeledAccount")}
      </div>
      <div className="min-w-0 text-xs">
        <div className="mb-1 text-muted md:hidden">{t("statusColumn")}</div>
        <div className={dimmed ? "text-muted" : "text-foreground"}>{status}</div>
        {statusDetail ? <div className="mt-0.5 text-muted">{statusDetail}</div> : null}
      </div>
      <div className="text-right">{actions ?? <span />}</div>
    </li>
  );
}

function ClaudeAccountActions({
  teamId,
  account,
}: {
  readonly teamId: string;
  readonly account: ClaudeAccountDescription;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const url = `/api/coderouter/claude-upstream/${encodeURIComponent(account.id)}?teamId=${encodeURIComponent(teamId)}`;

  const toggle = async () => {
    if (status.state === "submitting") return;
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ state: account.state === "disabled" ? "active" : "disabled" }),
      });
      if (!response.ok) {
        setStatus({ state: "error", message: errorMessageForStatus(response.status, t, t("updateError")) });
        return;
      }
      setStatus(idleStatus);
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("updateError") });
    }
  };

  const remove = async () => {
    if (status.state === "submitting") return;
    setConfirmOpen(false);
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(url, { method: "DELETE" });
      if (!response.ok && response.status !== 404) {
        setStatus({ state: "error", message: errorMessageForStatus(response.status, t, t("removeError")) });
        return;
      }
      setStatus(idleStatus);
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("removeError") });
    }
  };

  return (
    <RowActions
      status={status}
      confirmOpen={confirmOpen}
      setConfirmOpen={setConfirmOpen}
      onConfirm={remove}
      confirmTitle={t("removeConfirmTitle")}
      confirmBody={t("removeClaudeConfirmBody")}
      t={t}
      leading={
        <button type="button" onClick={toggle} disabled={status.state === "submitting"} className={buttonClass}>
          {account.state === "disabled" ? t("enableAction") : t("disableAction")}
        </button>
      }
    />
  );
}

function SharedAccountActions({
  teamId,
  accountId,
}: {
  readonly teamId: string;
  readonly accountId: string;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);
  const [confirmOpen, setConfirmOpen] = useState(false);

  const remove = async () => {
    if (status.state === "submitting") return;
    setConfirmOpen(false);
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/subrouter/accounts/${encodeURIComponent(accountId)}?teamId=${encodeURIComponent(teamId)}`,
        { method: "DELETE" },
      );
      if (!response.ok) {
        setStatus({
          state: "error",
          message: errorMessageForStatus(response.status, t, t("removeError"), t("notConfiguredTitle")),
        });
        return;
      }
      setStatus(idleStatus);
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("removeError") });
    }
  };

  return (
    <RowActions
      status={status}
      confirmOpen={confirmOpen}
      setConfirmOpen={setConfirmOpen}
      onConfirm={remove}
      confirmTitle={t("removeConfirmTitle")}
      confirmBody={t("removeSharedConfirmBody")}
      t={t}
    />
  );
}

function RowActions({
  status,
  confirmOpen,
  setConfirmOpen,
  onConfirm,
  confirmTitle,
  confirmBody,
  leading,
  t,
}: {
  readonly status: FormStatus;
  readonly confirmOpen: boolean;
  readonly setConfirmOpen: (open: boolean) => void;
  readonly onConfirm: () => void;
  readonly confirmTitle: string;
  readonly confirmBody: string;
  readonly leading?: ReactNode;
  readonly t: Translator;
}) {
  return (
    <div>
      <div className="flex justify-end gap-2">
        {leading}
        <button
          type="button"
          onClick={() => setConfirmOpen(true)}
          disabled={status.state === "submitting"}
          className={buttonClass}
        >
          {status.state === "submitting" ? t("removingAction") : t("removeAction")}
        </button>
      </div>
      {status.state === "error" && status.message ? (
        <div className="mt-1 text-xs text-foreground">{status.message}</div>
      ) : null}
      <Modal open={confirmOpen} onOpenChange={setConfirmOpen}>
        <Dialog.Title className="text-left text-sm font-medium">{confirmTitle}</Dialog.Title>
        <Dialog.Description className="mt-2 text-left text-xs text-muted">
          {confirmBody}
        </Dialog.Description>
        <div className="mt-5 flex justify-end gap-2">
          <Dialog.Close className={buttonClass}>{t("cancelAction")}</Dialog.Close>
          <button type="button" onClick={onConfirm} className={primaryButtonClass}>
            {t("removeAction")}
          </button>
        </div>
      </Modal>
    </div>
  );
}

function AddAccountPanel({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const [kind, setKind] = useState<AddKind>("anthropic_api_key");
  return (
    <div className="mt-3 border border-border p-3">
      <h3 className="text-sm font-medium">{t("addTitle")}</h3>
      <Tabs.Root
        value={kind}
        onValueChange={(value) => setKind(value as AddKind)}
        className="mt-2"
      >
        <Tabs.List aria-label={t("kindSelectorLabel")} className="flex flex-wrap gap-2">
          {ADD_KINDS.map((candidate) => (
            <Tabs.Tab
              key={candidate}
              value={candidate}
              className="border border-border px-2 py-1 text-xs text-muted hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground data-[active]:border-foreground data-[active]:text-foreground"
            >
              {addKindLabel(candidate, t)}
            </Tabs.Tab>
          ))}
        </Tabs.List>
        <Tabs.Panel value={kind} className="mt-3">
          {kind === "codex" ? (
            <CliInstructions
              body={t("codexBody")}
              command="npx coderouter@latest add codex"
              t={t}
            />
          ) : kind === "opencode" ? (
            <CliInstructions
              body={t("opencodeBody")}
              command="npx coderouter@latest add opencode"
              t={t}
            />
          ) : kind === "openai-apikey" || kind === "openrouter-apikey" ? (
            <ApiKeyForm key={kind} teamId={teamId} kind={kind} />
          ) : (
            <ClaudeUpstreamForm key={kind} teamId={teamId} kind={kind} />
          )}
        </Tabs.Panel>
      </Tabs.Root>
    </div>
  );
}

function CliInstructions({
  body,
  command,
  t,
}: {
  readonly body: string;
  readonly command: string;
  readonly t: Translator;
}) {
  return (
    <div>
      <p className="text-xs text-muted">{body}</p>
      <div className="mt-2 flex items-center justify-between gap-3 border border-border px-3 py-2">
        <code className="min-w-0 break-all font-mono text-xs text-foreground">{command}</code>
        <CopyButton value={command} label={t("copyCommand")} copiedLabel={t("copied")} />
      </div>
    </div>
  );
}

/**
 * Stores an OpenAI or OpenRouter key as a coderouter account. Codex on this
 * team's machines then routes Responses calls through it, next to any Codex
 * sign-ins, and moves off it on a rate limit or a rejected key.
 */
function ApiKeyForm({
  teamId,
  kind,
}: {
  readonly teamId: string;
  readonly kind: ApiKeyAddKind;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status.state === "submitting") return;
    const form = event.currentTarget;
    const data = new FormData(form);
    const label = String(data.get("label") ?? "").trim();
    setStatus({ state: "submitting" });
    try {
      const response = await fetch("/api/coderouter/accounts", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cmux-team-id": teamId },
        body: JSON.stringify({
          provider: kind,
          apiKey: String(data.get("apiKey") ?? "").trim(),
          ...(label ? { label } : {}),
        }),
      });
      if (!response.ok) {
        setStatus({
          state: "error",
          message: errorMessageForStatus(response.status, t, t("saveError")),
        });
        return;
      }
      form.reset();
      setStatus({ state: "success", message: t("saveSuccess") });
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("saveError") });
    }
  };

  return (
    <form onSubmit={submit} className="space-y-3">
      <p className="text-xs text-muted">
        {kind === "openai-apikey" ? t("openAiKeyHint") : t("openRouterKeyHint")}
      </p>
      <Field
        label={t("apiKeyField")}
        name="apiKey"
        placeholder={kind === "openai-apikey" ? "sk-proj-..." : "sk-or-v1-..."}
      />
      <Field
        label={t("labelField")}
        name="label"
        placeholder={t("labelPlaceholder")}
        required={false}
        secret={false}
        mono={false}
      />
      <div className="flex flex-wrap items-center gap-3">
        <button type="submit" disabled={status.state === "submitting"} className={primaryButtonClass}>
          {status.state === "submitting" ? t("savingAction") : t("saveAction")}
        </button>
        {status.message ? (
          <span className={`text-xs ${status.state === "error" ? "text-foreground" : "text-muted"}`}>
            {status.message}
          </span>
        ) : null}
      </div>
    </form>
  );
}

function ClaudeUpstreamForm({
  teamId,
  kind,
}: {
  readonly teamId: string;
  readonly kind: ClaudeUpstreamKind;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const router = useRouter();
  const [status, setStatus] = useState<FormStatus>(idleStatus);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status.state === "submitting") return;
    const form = event.currentTarget;
    const body = bodyForKind(kind, new FormData(form));
    setStatus({ state: "submitting" });
    try {
      const response = await fetch(
        `/api/coderouter/claude-upstream?teamId=${encodeURIComponent(teamId)}`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        },
      );
      if (!response.ok) {
        setStatus({
          state: "error",
          message: errorMessageForStatus(response.status, t, t("saveError")),
        });
        return;
      }
      form.reset();
      setStatus({ state: "success", message: t("saveSuccess") });
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("saveError") });
    }
  };

  return (
    <form onSubmit={submit} className="space-y-3">
      {kind === "anthropic_oauth" ? (
        <p className="text-xs text-muted">
          {t("oauthHint")} <code className="font-mono">claude setup-token</code>
        </p>
      ) : null}
      {kind === "anthropic_api_key" ? (
        <Field label={t("apiKeyField")} name="apiKey" placeholder="sk-ant-api03-..." />
      ) : null}
      {kind === "anthropic_oauth" ? (
        <Field label={t("oauthTokenField")} name="token" placeholder="sk-ant-oat01-..." />
      ) : null}
      {kind === "bedrock" ? (
        <>
          <Field label={t("regionField")} name="region" placeholder="us-west-2" secret={false} />
          <Field label={t("accessKeyIdField")} name="accessKeyId" placeholder="AKIA..." />
          <Field label={t("secretAccessKeyField")} name="secretAccessKey" placeholder="" />
          <Field
            label={t("sessionTokenField")}
            name="sessionToken"
            placeholder={t("optionalPlaceholder")}
            required={false}
          />
        </>
      ) : null}
      <Field
        label={t("labelField")}
        name="label"
        placeholder={t("labelPlaceholder")}
        required={false}
        secret={false}
        mono={false}
      />
      <div className="flex flex-wrap items-center gap-3">
        <button type="submit" disabled={status.state === "submitting"} className={primaryButtonClass}>
          {status.state === "submitting" ? t("savingAction") : t("saveAction")}
        </button>
        {status.message ? (
          <span className={`text-xs ${status.state === "error" ? "text-foreground" : "text-muted"}`}>
            {status.message}
          </span>
        ) : null}
      </div>
    </form>
  );
}

function Field({
  label,
  name,
  placeholder,
  required = true,
  secret = true,
  mono = true,
}: {
  readonly label: string;
  readonly name: string;
  readonly placeholder: string;
  readonly required?: boolean;
  readonly secret?: boolean;
  readonly mono?: boolean;
}) {
  const id = `coderouter-account-${name}`;
  return (
    <label htmlFor={id} className="block">
      <span className="mb-1 block text-xs text-muted">{label}</span>
      <input
        id={id}
        name={name}
        type={secret ? "password" : "text"}
        autoComplete="off"
        spellCheck={false}
        required={required}
        placeholder={placeholder}
        className={mono ? inputClass : inputClass.replace("font-mono ", "")}
      />
    </label>
  );
}

function bodyForKind(kind: ClaudeUpstreamKind, data: FormData): Record<string, string> {
  const field = (name: string) => String(data.get(name) ?? "").trim();
  const label = field("label");
  const withLabel = (body: Record<string, string>) => (label ? { ...body, label } : body);
  switch (kind) {
    case "anthropic_api_key":
      return withLabel({ kind, apiKey: field("apiKey") });
    case "anthropic_oauth":
      return withLabel({ kind, token: field("token") });
    case "bedrock": {
      const sessionToken = field("sessionToken");
      return withLabel({
        kind,
        region: field("region"),
        accessKeyId: field("accessKeyId"),
        secretAccessKey: field("secretAccessKey"),
        ...(sessionToken ? { sessionToken } : {}),
      });
    }
  }
}

function claudeKindLabel(kind: ClaudeUpstreamKind, t: Translator): string {
  switch (kind) {
    case "anthropic_api_key":
      return t("kindAnthropicApiKey");
    case "anthropic_oauth":
      return t("kindClaudeOauth");
    case "bedrock":
      return t("kindBedrock");
  }
}

function addKindLabel(kind: AddKind, t: Translator): string {
  switch (kind) {
    case "codex":
      return t("kindCodex");
    case "opencode":
      return t("kindOpencode");
    case "openai-apikey":
      return t("kindOpenAiApiKey");
    case "openrouter-apikey":
      return t("kindOpenRouterApiKey");
    default:
      return claudeKindLabel(kind, t);
  }
}

/** Provider names for accounts `cr add` stores. */
function nativeKindLabel(kind: CodeRouterAccountSummary["provider"], t: Translator): string {
  switch (kind) {
    case "codex":
      return t("kindCodex");
    case "opencode-go":
      return t("kindOpencodeGo");
    case "openai-apikey":
      return t("kindOpenAiApiKey");
    case "openrouter-apikey":
      return t("kindOpenRouterApiKey");
  }
}

/** Provider names for accounts held by the hosted subrouter. */
function sharedKindLabel(kind: string, t: Translator): string {
  switch (kind) {
    case "claude":
      return t("kindClaudeOauth");
    case "anthropic-apikey":
      return t("kindAnthropicApiKey");
    case "codex":
      return t("kindCodex");
    case "openai-apikey":
      return t("kindOpenAiApiKey");
    default:
      return t("kindUnknown");
  }
}

function errorMessageForStatus(
  status: number,
  t: Translator,
  fallback: string,
  unavailable: string = fallback,
): string {
  if (status === 400) return t("validationError");
  if (status === 403) return t("teamAccessError");
  if (status === 503) return unavailable;
  return fallback;
}
