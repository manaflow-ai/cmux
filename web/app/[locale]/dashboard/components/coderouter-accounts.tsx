"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useNow, useTranslations } from "next-intl";
import { useState } from "react";
import { useRouter } from "../../../../i18n/navigation";
import { Modal } from "../../components/modal";
import type { CodeRouterAccountSummary } from "../../../../services/coderouter/types";

/** One `coderouter_accounts` row plus the provider usage fan-out result. */
export type CoderouterAccountView = CodeRouterAccountSummary & {
  readonly usage?: unknown;
  readonly usageError?: string;
};

type FormStatus = {
  readonly state: "idle" | "submitting" | "error";
  readonly message?: string;
};

const idleStatus: FormStatus = { state: "idle" };
const buttonClass =
  "border border-border px-3 py-1.5 text-sm transition-colors hover:bg-foreground hover:text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";
const primaryButtonClass =
  "border border-foreground bg-foreground px-3 py-1.5 text-sm text-background transition-colors hover:bg-background hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground disabled:cursor-not-allowed disabled:opacity-60";

/**
 * The team's coderouter subscription accounts (ChatGPT Codex, OpenCode Go):
 * the pool `cr add codex` fills and the codex leg spreads sessions across.
 * Every account is listed with its state, cooldown, live usage windows, and
 * bound sessions; managers can remove one.
 */
export function CoderouterAccountsSection({
  teamId,
  accounts,
  canManage,
  loadFailed,
}: {
  readonly teamId: string;
  readonly accounts: readonly CoderouterAccountView[];
  readonly canManage: boolean;
  readonly loadFailed: boolean;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
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
      ) : accounts.length === 0 ? (
        <div className="border border-border p-3">
          <div className="text-sm font-medium">{t("emptyTitle")}</div>
          <p className="mt-1 text-xs text-muted">
            {t("emptyBody")} <code className="font-mono">npx coderouter@latest add codex</code>
          </p>
        </div>
      ) : (
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
      )}
    </section>
  );
}

function AccountRow({
  teamId,
  account,
  canManage,
}: {
  readonly teamId: string;
  readonly account: CoderouterAccountView;
  readonly canManage: boolean;
}) {
  const t = useTranslations("dashboard.coderouterAccounts");
  const now = useNow();
  const cooling = account.cooldownUntil !== null && new Date(account.cooldownUntil).getTime() > now.getTime();
  const usage = usageWindows(account.usage);
  return (
    <li className="flex flex-wrap items-center justify-between gap-3 px-3 py-2 text-sm">
      <div className="min-w-0">
        <div>
          {providerLabel(account.provider, t)}
          <span className="text-muted"> · {account.label || account.providerAccountId}</span>
        </div>
        <div className="mt-0.5 text-xs text-muted">
          {cooling
            ? t("coolingDown", { seconds: Math.max(1, Math.ceil((new Date(account.cooldownUntil!).getTime() - now.getTime()) / 1000)) })
            : stateLabel(account.state, t)}
          {account.lastFailureCode ? ` · ${t("lastFailure", { code: account.lastFailureCode })}` : ""}
          {" · "}
          {t("activeSessions", { count: account.activeSessions })}
        </div>
        <div className="mt-0.5 font-mono text-xs text-muted">
          {account.usageError
            ? t("usageUnavailable")
            : usage.length === 0
              ? t("usageUnknown")
              : usage.map((window) => t(window.kind === "primary" ? "usagePrimary" : "usageSecondary", { percent: window.usedPercent })).join(" · ")}
        </div>
      </div>
      {canManage ? <RemoveAccountButton teamId={teamId} accountId={account.id} /> : null}
    </li>
  );
}

function RemoveAccountButton({ teamId, accountId }: { readonly teamId: string; readonly accountId: string }) {
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
        `/api/coderouter/accounts/${encodeURIComponent(accountId)}?teamId=${encodeURIComponent(teamId)}`,
        { method: "DELETE" },
      );
      if (!response.ok && response.status !== 404) {
        setStatus({ state: "error", message: response.status === 403 ? t("teamAccessError") : t("removeError") });
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
      <button type="button" onClick={() => setConfirmOpen(true)} disabled={status.state === "submitting"} className={buttonClass}>
        {status.state === "submitting" ? t("removingAction") : t("removeAction")}
      </button>
      {status.state === "error" && status.message ? (
        <div className="mt-1 text-xs text-foreground">{status.message}</div>
      ) : null}
      <Modal open={confirmOpen} onOpenChange={setConfirmOpen}>
        <Dialog.Title className="text-left text-sm font-medium">{t("removeConfirmTitle")}</Dialog.Title>
        <Dialog.Description className="mt-2 text-left text-xs text-muted">{t("removeConfirmBody")}</Dialog.Description>
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

type Translator = ReturnType<typeof useTranslations<"dashboard.coderouterAccounts">>;

function providerLabel(provider: string, t: Translator): string {
  switch (provider) {
    case "codex":
      return t("providerCodex");
    case "opencode-go":
      return t("providerOpencode");
    default:
      return provider;
  }
}

function stateLabel(state: CodeRouterAccountSummary["state"], t: Translator): string {
  switch (state) {
    case "active":
      return t("stateActive");
    case "refreshing":
      return t("stateRefreshing");
    case "expired":
      return t("stateExpired");
    case "broken":
      return t("stateBroken");
  }
}

/**
 * ChatGPT's usage payload: `rate_limit.primary_window` (the 5-hour window)
 * and `rate_limit.secondary_window` (the weekly one), each with
 * `used_percent`. Anything else renders as unknown rather than throwing.
 */
export function usageWindows(value: unknown): readonly { kind: "primary" | "secondary"; usedPercent: number }[] {
  if (typeof value !== "object" || value === null) return [];
  const rate = (value as { rate_limit?: unknown }).rate_limit;
  if (typeof rate !== "object" || rate === null) return [];
  const windows: { kind: "primary" | "secondary"; usedPercent: number }[] = [];
  for (const kind of ["primary", "secondary"] as const) {
    const window = (rate as Record<string, unknown>)[`${kind}_window`];
    if (typeof window !== "object" || window === null) continue;
    const used = (window as { used_percent?: unknown }).used_percent;
    if (typeof used === "number" && Number.isFinite(used)) {
      windows.push({ kind, usedPercent: Math.max(0, Math.min(100, Math.round(used))) });
    }
  }
  return windows;
}
