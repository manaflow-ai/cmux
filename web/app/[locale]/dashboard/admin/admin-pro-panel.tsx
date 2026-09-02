"use client";

import { useFormatter, useTranslations } from "next-intl";
import { useId, useRef, useState } from "react";

type AdminUserRow = {
  readonly id: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly displayName: string | null;
  readonly signedUpAt: string;
  readonly isPro: boolean;
  readonly manualPlanId: string | null;
  readonly metadataPlanId: string | null;
  readonly stripe: {
    readonly subscriptionStatus: string | null;
    readonly cancelAtPeriodEnd: boolean;
    readonly hasActiveSubscription: boolean;
  };
  readonly lastGrant: {
    readonly plan: string | null;
    readonly byUserId: string;
    readonly byEmail: string | null;
    readonly at: string;
  } | null;
};

type SearchState =
  | { readonly kind: "idle" }
  | { readonly kind: "searching" }
  | { readonly kind: "results"; readonly users: readonly AdminUserRow[] }
  | { readonly kind: "error"; readonly message: string };

type MutationState =
  | { readonly kind: "idle" }
  | { readonly kind: "saving"; readonly userId: string }
  | { readonly kind: "error"; readonly userId: string; readonly message: string };

type GrantPlan = "pro" | "founders" | null;

const buttonClass =
  "border border-border bg-background px-2.5 py-1 text-xs font-medium text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background disabled:cursor-not-allowed disabled:opacity-60 disabled:hover:bg-background disabled:hover:text-foreground";

export function AdminProPanel() {
  const t = useTranslations("dashboard.admin");
  const inputId = useId();
  const [query, setQuery] = useState("");
  const [search, setSearch] = useState<SearchState>({ kind: "idle" });
  const [mutation, setMutation] = useState<MutationState>({ kind: "idle" });
  const requestSeq = useRef(0);

  async function runSearch(value: string) {
    const trimmed = value.trim();
    if (trimmed.length < 2) {
      setSearch({ kind: "idle" });
      return;
    }
    const seq = ++requestSeq.current;
    setSearch({ kind: "searching" });
    let response: Response;
    try {
      response = await fetch(`/api/admin/users?q=${encodeURIComponent(trimmed)}`, {
        headers: { accept: "application/json" },
      });
    } catch {
      if (seq === requestSeq.current) setSearch({ kind: "error", message: t("errors.network") });
      return;
    }
    if (seq !== requestSeq.current) return;
    if (!response.ok) {
      setSearch({ kind: "error", message: errorMessage(t, response.status) });
      return;
    }
    let body: { users: AdminUserRow[] };
    try {
      body = (await response.json()) as { users: AdminUserRow[] };
    } catch {
      if (seq === requestSeq.current) setSearch({ kind: "error", message: t("errors.generic") });
      return;
    }
    // A newer search may have started while this body was streaming.
    if (seq !== requestSeq.current) return;
    setSearch({ kind: "results", users: body.users });
  }

  async function setGrant(userId: string, plan: GrantPlan) {
    setMutation({ kind: "saving", userId });
    let response: Response;
    try {
      response = await fetch("/api/admin/users", {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ userId, plan }),
      });
    } catch {
      setMutation({ kind: "error", userId, message: t("errors.network") });
      return;
    }
    if (!response.ok) {
      setMutation({ kind: "error", userId, message: errorMessage(t, response.status) });
      return;
    }
    const body = (await response.json()) as { user: AdminUserRow };
    setSearch((current) =>
      current.kind === "results"
        ? {
            kind: "results",
            users: current.users.map((user) => (user.id === body.user.id ? body.user : user)),
          }
        : current,
    );
    setMutation({ kind: "idle" });
  }

  return (
    <div className="space-y-4">
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void runSearch(query);
        }}
        className="flex max-w-xl flex-col gap-2"
      >
        <label className="text-xs font-medium text-muted" htmlFor={inputId}>
          {t("search.label")}
        </label>
        <div className="flex gap-2">
          <input
            id={inputId}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("search.placeholder")}
            autoComplete="off"
            spellCheck={false}
            className="min-w-0 flex-1 border border-border bg-background px-3 py-1.5 font-mono text-xs text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          />
          <button type="submit" disabled={search.kind === "searching"} className={buttonClass}>
            {search.kind === "searching" ? t("search.searching") : t("search.button")}
          </button>
        </div>
        <p className="text-xs text-muted">{t("search.hint")}</p>
      </form>

      {search.kind === "error" ? (
        <p className="border border-border p-3 text-sm text-muted" role="alert">
          {search.message}
        </p>
      ) : null}

      {search.kind === "results" && search.users.length === 0 ? (
        <p className="border border-border p-3 text-sm text-muted">{t("results.empty")}</p>
      ) : null}

      {search.kind === "results" && search.users.length > 0 ? (
        <div className="overflow-x-auto border border-border">
          <table className="w-full min-w-[40rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.user")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.access")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.stripe")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.grant")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.actions")}</th>
              </tr>
            </thead>
            <tbody>
              {search.users.map((user) => (
                <UserRow
                  key={user.id}
                  user={user}
                  t={t}
                  saving={mutation.kind === "saving" && mutation.userId === user.id}
                  error={
                    mutation.kind === "error" && mutation.userId === user.id
                      ? mutation.message
                      : null
                  }
                  onGrant={(plan) => void setGrant(user.id, plan)}
                />
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}

function UserRow({
  user,
  t,
  saving,
  error,
  onGrant,
}: {
  user: AdminUserRow;
  t: ReturnType<typeof useTranslations<"dashboard.admin">>;
  saving: boolean;
  error: string | null;
  onGrant: (plan: GrantPlan) => void;
}) {
  const format = useFormatter();
  const grantLabel = user.manualPlanId
    ? t("grant.current", { plan: user.manualPlanId })
    : t("grant.none");
  return (
    <tr className="border-b border-border last:border-b-0 align-top">
      <td className="px-3 py-2">
        <div className="font-mono text-foreground">{user.email ?? t("results.noEmail")}</div>
        <div className="mt-0.5 text-muted">
          {user.displayName ? `${user.displayName} · ` : ""}
          {user.emailVerified ? t("results.verified") : t("results.unverified")}
        </div>
        <div className="mt-0.5 font-mono text-[10px] text-muted">{user.id}</div>
      </td>
      <td className="px-3 py-2">
        <span
          className={`inline-block border px-1.5 py-0.5 font-medium ${
            user.isPro ? "border-foreground text-foreground" : "border-border text-muted"
          }`}
        >
          {user.isPro ? t("access.pro") : t("access.free")}
        </span>
      </td>
      <td className="px-3 py-2 text-muted">
        {user.stripe.subscriptionStatus
          ? `${user.stripe.subscriptionStatus}${user.stripe.cancelAtPeriodEnd ? ` · ${t("results.cancelling")}` : ""}`
          : t("results.noSubscription")}
      </td>
      <td className="px-3 py-2 text-muted">
        <div>{grantLabel}</div>
        {user.lastGrant ? (
          <div className="mt-0.5 text-[10px]">
            {t("grant.by", {
              who: user.lastGrant.byEmail ?? user.lastGrant.byUserId,
              when: formatGrantTime(format, user.lastGrant.at),
            })}
          </div>
        ) : null}
      </td>
      <td className="px-3 py-2">
        <div className="flex flex-wrap gap-1.5">
          <button
            type="button"
            disabled={saving || user.manualPlanId === "pro"}
            onClick={() => onGrant("pro")}
            className={buttonClass}
          >
            {t("actions.grantPro")}
          </button>
          <button
            type="button"
            disabled={saving || user.manualPlanId === "founders"}
            onClick={() => onGrant("founders")}
            className={buttonClass}
          >
            {t("actions.grantFounders")}
          </button>
          <button
            type="button"
            disabled={saving || user.manualPlanId === null}
            onClick={() => onGrant(null)}
            className={buttonClass}
          >
            {t("actions.removeGrant")}
          </button>
        </div>
        {saving ? <p className="mt-1 text-muted">{t("actions.saving")}</p> : null}
        {error ? (
          <p className="mt-1 text-muted" role="alert">
            {error}
          </p>
        ) : null}
        {user.stripe.hasActiveSubscription && user.manualPlanId === null ? (
          <p className="mt-1 max-w-[16rem] text-muted">{t("grant.stripeNote")}</p>
        ) : null}
      </td>
    </tr>
  );
}

function formatGrantTime(format: ReturnType<typeof useFormatter>, iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return format.dateTime(date, { dateStyle: "medium", timeStyle: "short" });
}

function errorMessage(
  t: ReturnType<typeof useTranslations<"dashboard.admin">>,
  status: number,
): string {
  if (status === 401 || status === 403) return t("errors.forbidden");
  if (status === 404) return t("errors.notFound");
  if (status === 409) return t("errors.conflict");
  return t("errors.generic");
}
