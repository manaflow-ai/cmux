"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { Tabs } from "@base-ui-components/react/tabs";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useFormatter, useNow, useTranslations } from "next-intl";
import { useState, type FormEvent, type ReactNode } from "react";
import { Modal } from "@/app/[locale]/components/modal";
import { DashboardSectionSkeleton } from "../../components/dashboard-skeleton";
import { EmptyState, SectionError } from "../../components/page-states";
import { CopyButton } from "../vault/copy-button";
import type {
  ClaudeAccountDescription,
  ClaudeUpstreamKind,
} from "@/services/coderouter/claudeUpstream";
import type { SubrouterAccount } from "@/services/subrouter/types";
import type { CodeRouterAccountSummary } from "@/services/coderouter/types";
import type {
  ClaudeAccountsState,
  CoderouterTransferTeam,
  NativeAccountsState,
  SharedAccountsState,
} from "../../lib/coderouter-types";
import { coderouterApiKeysQuery } from "../../queries/coderouter";
import {
  accountSharingMutation,
  accountWriteErrorKey,
  addApiKeyAccountMutation,
  addClaudeUpstreamMutation,
  apiKeyCreateErrorKey,
  claudeAccountMutation,
  createApiKeyMutation,
  removeNativeAccountMutation,
  removeSharedAccountMutation,
  revokeApiKeyMutation,
  transferErrorKeyFor,
  transferNativeAccountMutation,
  type ClaudeUpstreamBody,
  type IssuedCoderouterApiKey,
} from "../../queries/coderouter-mutations";

/**
 * Every account the team routes through, in one list: the Claude upstream
 * accounts stored by the web app (Anthropic API key, Claude Code OAuth token,
 * Bedrock) and the shared accounts held by the hosted subrouter (Codex and
 * the CLI-added Claude accounts). Both kinds share one row shape and one add
 * panel, so a team never has to know which backend holds which credential.
 */
export type { ClaudeAccountsState, CoderouterTransferTeam, NativeAccountsState, SharedAccountsState };

type FormStatus = {
  readonly state: "idle" | "submitting" | "success" | "error";
  readonly message?: string;
};

/** The row and form status a mutation implies; `message` is the error or success copy. */
function mutationStatus(
  mutation: { readonly isPending: boolean; readonly isError: boolean; readonly isSuccess: boolean },
  messages: { readonly error: () => string; readonly success?: () => string },
): FormStatus {
  if (mutation.isPending) return { state: "submitting" };
  if (mutation.isError) return { state: "error", message: messages.error() };
  if (mutation.isSuccess && messages.success) return { state: "success", message: messages.success() };
  return { state: "idle" };
}

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
type Translator = ReturnType<typeof useTranslations<"dashboard.coderouterAccounts">>;

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
          <EmptyState title={t("emptyTitle")} body={t("emptyBody")} />
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
  const [issued, setIssued] = useState<IssuedCoderouterApiKey & { readonly teamId: string } | null>(null);
  // The key list loads beside the page.
  const keysQuery = useQuery(coderouterApiKeysQuery(teamId));
  const createKey = useMutation(createApiKeyMutation(useQueryClient(), teamId));
  const status = mutationStatus(createKey, { error: () => t(apiKeyCreateErrorKey(createKey.error)) });
  const visibleKeys = keysQuery.data ?? null;
  const visibleIssued = issued?.teamId === teamId ? issued : null;

  const create = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (createKey.isPending) return;
    const form = event.currentTarget;
    const label = String(new FormData(form).get("apiKeyLabel") ?? "").trim();
    createKey.mutate(label, {
      onSuccess: (created) => {
        form.reset();
        setIssued({ ...created, teamId });
      },
    });
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

      {keysQuery.isPending ? <DashboardSectionSkeleton variant="table" columns={4} rows={2} /> : null}
      {keysQuery.isError ? (
        <SectionError error={keysQuery.error} section={t("apiKeysTitle")} onRetry={() => keysQuery.refetch()} />
      ) : null}
      {visibleKeys && visibleKeys.length === 0 ? <EmptyState title={t("apiKeysEmptyTitle")} body={t("apiKeysEmptyHint")} /> : null}
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
                  <div className="text-right">{canManage && !key.revokedAt ? <ApiKeyRevokeAction teamId={teamId} keyId={key.id} /> : null}</div>
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
}: {
  readonly teamId: string;
  readonly keyId: string;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const [open, setOpen] = useState(false);
  const revokeKey = useMutation(revokeApiKeyMutation(useQueryClient(), teamId));
  const pending = revokeKey.isPending;
  const error = revokeKey.isError;
  const revoke = () => {
    if (pending) return;
    revokeKey.mutate(keyId, { onSuccess: () => setOpen(false) });
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
          <button type="button" onClick={revoke} className={primaryButtonClass}>{t("revokeApiKeyAction")}</button>
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
  const sharing = useMutation(accountSharingMutation(useQueryClient(), teamId));
  const pending = sharing.isPending;
  const error = sharing.isError;
  function updateSharing() {
    if (pending) return;
    sharing.mutate({ accountId, family, visibility: visibility === "private" ? "team" : "private" });
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
  const removal = useMutation(removeNativeAccountMutation(useQueryClient(), teamId));
  const status = mutationStatus(removal, { error: () => t(accountWriteErrorKey(removal.error, "removeError")) });
  const [confirmOpen, setConfirmOpen] = useState(false);

  const remove = () => {
    if (removal.isPending) return;
    setConfirmOpen(false);
    removal.mutate(accountId);
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
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<"choose" | "confirm">("choose");
  const [destinationId, setDestinationId] = useState(teams[0]?.id ?? "");
  const transfer = useMutation(transferNativeAccountMutation(useQueryClient(), teamId));
  const status = mutationStatus(transfer, { error: () => t(transferErrorKeyFor(transfer.error)) });
  const destination = teams.find((team) => team.id === destinationId) ?? teams[0];

  const openDialog = () => {
    setStep("choose");
    setDestinationId(teams[0]?.id ?? "");
    transfer.reset();
    setOpen(true);
  };

  const confirm = () => {
    if (transfer.isPending || !destination) return;
    transfer.mutate({ accountId, destinationTeamId: destination.id }, {
      onSuccess: () => {
        setOpen(false);
        onTransferred(t("transferSuccess", { account: accountLabel, destination: destination.name }));
      },
    });
  };

  const submitting = transfer.isPending;
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
              <button type="button" className={buttonClass} disabled={submitting} onClick={() => { transfer.reset(); setStep("choose"); }}>
                {t("backAction")}
              </button>
              <Dialog.Close className={buttonClass} disabled={submitting}>{t("cancelAction")}</Dialog.Close>
              <button type="button" className={primaryButtonClass} disabled={submitting} onClick={confirm}>
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
  // Toggle and remove share one mutation, so they share one pending and error line.
  const write = useMutation(claudeAccountMutation(useQueryClient(), teamId));
  const status = mutationStatus(write, {
    error: () => t(accountWriteErrorKey(write.error, write.variables?.action === "remove" ? "removeError" : "updateError")),
  });
  const [confirmOpen, setConfirmOpen] = useState(false);

  const toggle = () => {
    if (write.isPending) return;
    write.mutate({ accountId: account.id, action: "setState", state: account.state === "disabled" ? "active" : "disabled" });
  };

  const remove = () => {
    if (write.isPending) return;
    setConfirmOpen(false);
    write.mutate({ accountId: account.id, action: "remove" });
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
  const removal = useMutation(removeSharedAccountMutation(useQueryClient(), teamId));
  const status = mutationStatus(removal, {
    error: () => t(accountWriteErrorKey(removal.error, "removeError", "notConfiguredTitle")),
  });
  const [confirmOpen, setConfirmOpen] = useState(false);

  const remove = () => {
    if (removal.isPending) return;
    setConfirmOpen(false);
    removal.mutate(accountId);
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
  const add = useMutation(addApiKeyAccountMutation(useQueryClient(), teamId));
  const status = mutationStatus(add, {
    error: () => t(accountWriteErrorKey(add.error, "saveError")),
    success: () => t("saveSuccess"),
  });

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (add.isPending) return;
    const form = event.currentTarget;
    const data = new FormData(form);
    add.mutate({
      provider: kind,
      apiKey: String(data.get("apiKey") ?? "").trim(),
      label: String(data.get("label") ?? "").trim(),
    }, { onSuccess: () => form.reset() });
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
  const add = useMutation(addClaudeUpstreamMutation(useQueryClient(), teamId));
  const status = mutationStatus(add, {
    error: () => t(accountWriteErrorKey(add.error, "saveError")),
    success: () => t("saveSuccess"),
  });

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (add.isPending) return;
    const form = event.currentTarget;
    add.mutate(bodyForKind(kind, new FormData(form)), { onSuccess: () => form.reset() });
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

function bodyForKind(kind: ClaudeUpstreamKind, data: FormData): ClaudeUpstreamBody {
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
