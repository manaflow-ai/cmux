"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useFormatter, useNow, useTranslations } from "next-intl";
import { useState, type FormEvent } from "react";
import { useRouter } from "../../../../i18n/navigation";
import { Modal } from "../../components/modal";
import type {
  ClaudeAccountDescription,
  ClaudeUpstreamKind,
} from "../../../../services/coderouter/claudeUpstream";

type FormStatus = {
  readonly state: "idle" | "submitting" | "success" | "error";
  readonly message?: string;
};

const idleStatus: FormStatus = { state: "idle" };
const KINDS: readonly ClaudeUpstreamKind[] = ["anthropic_api_key", "anthropic_oauth", "bedrock"];

const inputClass =
  "w-full border border-border bg-background px-2 py-1.5 font-mono text-xs text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground";
const buttonClass =
  "border border-border px-3 py-1.5 text-sm transition-colors hover:bg-foreground hover:text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";
const primaryButtonClass =
  "border border-foreground bg-foreground px-3 py-1.5 text-sm text-background transition-colors hover:bg-background hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";

/**
 * The team's Claude upstream accounts: every account listed with its health,
 * plus the add form. Requests from a Cloud VM are pinned to one account and
 * move to another when it cools down, so the list is the whole routing table.
 */
export function ClaudeUpstreamSection({
  teamId,
  accounts,
  canManage,
  loadFailed,
}: {
  readonly teamId: string;
  readonly accounts: readonly ClaudeAccountDescription[];
  readonly canManage: boolean;
  readonly loadFailed: boolean;
}) {
  const t = useTranslations("dashboard.claudeUpstream");
  return (
    <section className="mb-4">
      <div className="mb-2">
        <h2 className="text-sm font-medium">{t("title")}</h2>
        <p className="mt-1 max-w-2xl text-xs text-muted">{t("description")}</p>
      </div>
      {loadFailed ? (
        <div className="border border-border p-3">
          <div className="text-sm font-medium">{t("loadErrorTitle")}</div>
          <p className="mt-1 text-xs text-muted">{t("loadErrorBody")}</p>
        </div>
      ) : (
        <div className="space-y-3">
          <AccountList teamId={teamId} accounts={accounts} canManage={canManage} />
          {canManage ? <AddAccountForm teamId={teamId} /> : null}
        </div>
      )}
    </section>
  );
}

function AccountList({
  teamId,
  accounts,
  canManage,
}: {
  readonly teamId: string;
  readonly accounts: readonly ClaudeAccountDescription[];
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.claudeUpstream");
  if (accounts.length === 0) {
    return (
      <div className="border border-border p-3">
        <div className="text-sm font-medium">{t("emptyTitle")}</div>
        <p className="mt-1 text-xs text-muted">{t("emptyBody")}</p>
      </div>
    );
  }
  return (
    <div className="border border-border">
      <div className="border-b border-border px-3 py-1.5 text-xs text-muted">
        {t("accountsLabel", { count: accounts.length })}
      </div>
      <ul className="divide-y divide-border">
        {accounts.map((account) => (
          <AccountRow key={account.id} teamId={teamId} account={account} canManage={canManage} />
        ))}
      </ul>
    </div>
  );
}

function AccountRow({
  teamId,
  account,
  canManage,
}: {
  readonly teamId: string;
  readonly account: ClaudeAccountDescription;
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.claudeUpstream");
  const format = useFormatter();
  const now = useNow();
  const cooling = account.cooldownUntil !== null && new Date(account.cooldownUntil).getTime() > now.getTime();
  const health = account.state === "broken"
    ? t("stateBroken", { code: account.lastFailureCode ?? "rejected" })
    : account.state === "disabled"
    ? t("stateDisabled")
    : cooling
      ? t("coolingDown", { until: format.dateTime(new Date(account.cooldownUntil!), { timeStyle: "short" }) })
      : t("stateActive");
  return (
    <li className="flex flex-wrap items-center justify-between gap-3 px-3 py-2 text-sm">
      <div className="min-w-0">
        <div>
          {kindLabel(account.kind, t)}
          {account.label ? <span className="text-muted"> · {account.label}</span> : null}
        </div>
        <div className="mt-0.5 font-mono text-xs text-muted">
          {account.identifier}
          {account.region ? ` · ${account.region}` : ""}
        </div>
        <div className="mt-0.5 text-xs text-muted">
          {health}
          {" · "}
          {account.lastUsedAt
            ? t("lastUsed", { at: format.relativeTime(new Date(account.lastUsedAt), now) })
            : t("neverUsed")}
          {account.lastFailureCode ? ` · ${t("lastFailure", { code: account.lastFailureCode })}` : ""}
        </div>
      </div>
      {canManage ? <AccountActions teamId={teamId} account={account} /> : null}
    </li>
  );
}

function AddAccountForm({ teamId }: { readonly teamId: string }) {
  const t = useTranslations("dashboard.claudeUpstream");
  const router = useRouter();
  const [kind, setKind] = useState<ClaudeUpstreamKind>("anthropic_api_key");
  const [status, setStatus] = useState<FormStatus>(idleStatus);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status.state === "submitting") return;
    const form = event.currentTarget;
    const data = new FormData(form);
    const body = bodyForKind(kind, data);
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
      const result: { alreadyExists?: boolean; validation?: string } = await response.json().catch(() => ({}));
      form.reset();
      setStatus({
        state: "success",
        message: result.alreadyExists
          ? t("alreadyAdded")
          : result.validation === "unreachable"
            ? t("saveSuccessUnverified")
            : t("saveSuccess"),
      });
      router.refresh();
    } catch {
      setStatus({ state: "error", message: t("saveError") });
    }
  };

  return (
    <div className="border border-border p-3">
      <div role="tablist" aria-label={t("kindSelectorLabel")} className="mb-3 flex flex-wrap gap-2">
        {KINDS.map((candidate) => (
          <button
            key={candidate}
            type="button"
            role="tab"
            aria-selected={candidate === kind}
            onClick={() => {
              setKind(candidate);
              setStatus(idleStatus);
            }}
            className={`px-2 py-1 text-xs focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
              candidate === kind ? "border border-foreground" : "border border-border text-muted hover:text-foreground"
            }`}
          >
            {kindLabel(candidate, t)}
          </button>
        ))}
      </div>
      <form onSubmit={submit} className="space-y-3">
        <Field label={t("labelField")} name="label" placeholder={t("labelPlaceholder")} required={false} secret={false} mono={false} />
        {kind === "anthropic_api_key" ? (
          <Field label={t("apiKeyField")} name="apiKey" placeholder="sk-ant-api03-..." />
        ) : null}
        {kind === "anthropic_oauth" ? (
          <>
            <Field label={t("oauthTokenField")} name="token" placeholder="sk-ant-oat01-..." />
            <p className="text-xs text-muted">
              {t("oauthHint")} <code className="font-mono">claude setup-token</code>
            </p>
          </>
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
    </div>
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
  const id = `claude-upstream-${name}`;
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

function AccountActions({
  teamId,
  account,
}: {
  readonly teamId: string;
  readonly account: ClaudeAccountDescription;
}) {
  const t = useTranslations("dashboard.claudeUpstream");
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
    <div className="text-right">
      <div className="flex justify-end gap-2">
        {account.state === "broken" ? null : (
          <button type="button" onClick={toggle} disabled={status.state === "submitting"} className={buttonClass}>
            {account.state === "disabled" ? t("enableAction") : t("disableAction")}
          </button>
        )}
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
        <Dialog.Title className="text-left text-sm font-medium">
          {t("removeConfirmTitle")}
        </Dialog.Title>
        <Dialog.Description className="mt-2 text-left text-xs text-muted">
          {t("removeConfirmBody")}
        </Dialog.Description>
        <div className="mt-5 flex justify-end gap-2">
          <Dialog.Close className={buttonClass}>{t("cancelAction")}</Dialog.Close>
          <button type="button" onClick={remove} className={primaryButtonClass}>
            {t("removeAction")}
          </button>
        </div>
      </Modal>
    </div>
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

type Translator = ReturnType<typeof useTranslations<"dashboard.claudeUpstream">>;

function kindLabel(kind: ClaudeUpstreamKind, t: Translator): string {
  switch (kind) {
    case "anthropic_api_key":
      return t("kindApiKey");
    case "anthropic_oauth":
      return t("kindOauth");
    case "bedrock":
      return t("kindBedrock");
  }
}

function errorMessageForStatus(status: number, t: Translator, fallback: string): string {
  if (status === 400) return t("validationError");
  if (status === 403) return t("teamAccessError");
  if (status === 422) return t("credentialRejected");
  return fallback;
}
