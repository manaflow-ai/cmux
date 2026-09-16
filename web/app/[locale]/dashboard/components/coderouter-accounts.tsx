"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { Tabs } from "@base-ui-components/react/tabs";
import { useFormatter, useNow, useTranslations } from "next-intl";
import { useState, type FormEvent, type ReactNode } from "react";
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

type Translator = ReturnType<typeof useTranslations<"dashboard.coderouterAccounts">>;

export function CoderouterAccountsSection({
  teamId,
  canManage,
  claude,
  native,
  shared,
}: {
  readonly teamId: string;
  readonly canManage: boolean;
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
                account={account}
                canManage={canManage}
              />
            ))}
            {nativeAccounts.map((account) => (
              <NativeAccountRow
                key={`native:${account.id}`}
                teamId={teamId}
                account={account}
                canManage={canManage}
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

      {canManage ? <AddAccountPanel teamId={teamId} /> : null}
    </section>
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
  account,
  canManage,
}: {
  readonly teamId: string;
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
      actions={canManage ? <ClaudeAccountActions teamId={teamId} account={account} /> : null}
      t={t}
    />
  );
}

function NativeAccountRow({
  teamId,
  account,
  canManage,
}: {
  readonly teamId: string;
  readonly account: CodeRouterAccountSummary;
  readonly canManage: boolean;
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
      actions={canManage ? <NativeAccountActions teamId={teamId} accountId={account.id} /> : null}
      t={t}
    />
  );
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
