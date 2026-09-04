"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useFormatter, useTranslations } from "next-intl";
import { useId, useRef, useState, type ReactNode } from "react";

import { Modal } from "../../components/modal";
import { AdminProList, type ProListSnapshotProps } from "./admin-pro-list";

type GrantRecord = {
  readonly plan: string | null;
  readonly byUserId: string;
  readonly byEmail: string | null;
  readonly at: string;
} | null;

type StripeState = {
  readonly subscriptionStatus: string | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly hasActiveSubscription: boolean;
};

type AdminUserRow = {
  readonly id: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly displayName: string | null;
  readonly signedUpAt: string;
  readonly isPro: boolean;
  readonly manualPlanId: string | null;
  readonly metadataPlanId: string | null;
  readonly stripe: StripeState;
  readonly lastGrant: GrantRecord;
};

type AdminTeamRow = {
  readonly id: string;
  readonly displayName: string;
  readonly createdAt: string | null;
  readonly memberCount: number | null;
  readonly isTeam: boolean;
  readonly manualPlanId: string | null;
  readonly metadataPlanId: string | null;
  readonly stripe: StripeState;
  readonly lastGrant: GrantRecord;
};

type PendingGrantRow = {
  readonly id: string;
  readonly email: string;
  readonly plan: string;
  readonly grantedByEmail: string | null;
  readonly createdAt: string;
};

type SearchResults = {
  readonly users: readonly AdminUserRow[];
  readonly teams: readonly AdminTeamRow[];
  readonly pendingGrants: readonly PendingGrantRow[];
};

type SearchState =
  | { readonly kind: "idle" }
  | { readonly kind: "searching" }
  | { readonly kind: "results"; readonly query: string; readonly results: SearchResults }
  | { readonly kind: "error"; readonly message: string };

/** Every mutation the page can perform. Each one is confirmed in a modal first. */
type PendingAction =
  | { readonly kind: "user-grant"; readonly user: AdminUserRow; readonly plan: "pro" | "founders" | null }
  | { readonly kind: "user-subscription"; readonly user: AdminUserRow; readonly action: "cancel" | "resume" }
  | { readonly kind: "team-grant"; readonly team: AdminTeamRow; readonly plan: "team" | null }
  | { readonly kind: "team-subscription"; readonly team: AdminTeamRow; readonly action: "cancel" | "resume" }
  | { readonly kind: "email-grant"; readonly email: string; readonly plan: "pro" | "founders" }
  | { readonly kind: "pending-revoke"; readonly grant: PendingGrantRow };

type MutationState =
  | { readonly kind: "idle" }
  | { readonly kind: "saving" }
  | { readonly kind: "error"; readonly message: string };

type Translate = ReturnType<typeof useTranslations<"dashboard.admin">>;

const buttonClass =
  "border border-border bg-background px-2.5 py-1 text-xs font-medium text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-background disabled:hover:text-foreground";
const primaryButtonClass =
  "border border-foreground bg-foreground px-3 py-1.5 text-xs font-medium text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50";
const dangerButtonClass =
  "border border-border bg-background px-2.5 py-1 text-xs font-medium text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:border-foreground disabled:cursor-not-allowed disabled:opacity-50";

export function AdminProPanel({ initialSnapshot }: { initialSnapshot: ProListSnapshotProps | null }) {
  const t = useTranslations("dashboard.admin");
  const inputId = useId();
  const [query, setQuery] = useState("");
  const [search, setSearch] = useState<SearchState>({ kind: "idle" });
  const [pending, setPending] = useState<PendingAction | null>(null);
  const [mutation, setMutation] = useState<MutationState>({ kind: "idle" });
  const [notice, setNotice] = useState<string | null>(null);
  const requestSeq = useRef(0);

  async function runSearch(value: string) {
    const trimmed = value.trim();
    // Every submit claims a new sequence number, including a too-short query,
    // so an older in-flight search cannot land on top of the reset state.
    const seq = ++requestSeq.current;
    if (trimmed.length < 2) {
      setSearch({ kind: "idle" });
      return;
    }
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
    let body: SearchResults;
    try {
      body = (await response.json()) as SearchResults;
    } catch {
      if (seq === requestSeq.current) setSearch({ kind: "error", message: t("errors.generic") });
      return;
    }
    // A newer search may have started while this body was streaming.
    if (seq !== requestSeq.current) return;
    setSearch({
      kind: "results",
      query: trimmed,
      results: {
        users: body.users ?? [],
        teams: body.teams ?? [],
        pendingGrants: body.pendingGrants ?? [],
      },
    });
  }

  async function confirmPending() {
    if (!pending) return;
    setMutation({ kind: "saving" });
    const request = mutationRequest(pending);
    let response: Response;
    try {
      response = await fetch(request.path, {
        method: request.method,
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify(request.body),
      });
    } catch {
      setMutation({ kind: "error", message: t("errors.network") });
      return;
    }
    if (!response.ok) {
      setMutation({ kind: "error", message: errorMessage(t, response.status) });
      return;
    }
    let body: {
      user?: AdminUserRow;
      team?: AdminTeamRow;
      pendingGrant?: PendingGrantRow;
      unclearedUserIds?: string[];
      action?: "cancel" | "resume";
    };
    try {
      body = await response.json();
    } catch {
      body = {};
    }
    applyMutationResult(pending, body);
    setMutation({ kind: "idle" });
    setNotice(
      body.unclearedUserIds && body.unclearedUserIds.length > 0
        ? t("notices.supersededNotCleared", { count: body.unclearedUserIds.length })
        : successNotice(t, pending),
    );
    setPending(null);
    if (pending.kind === "user-subscription" || pending.kind === "team-subscription") {
      // Subscription state comes back from Stripe; refresh the rows.
      if (search.kind === "results") void runSearch(search.query);
    }
  }

  function applyMutationResult(
    action: PendingAction,
    body: { user?: AdminUserRow; team?: AdminTeamRow; pendingGrant?: PendingGrantRow },
  ) {
    setSearch((current) => {
      if (current.kind !== "results") return current;
      const results = current.results;
      if (body.user) {
        const exists = results.users.some((user) => user.id === body.user!.id);
        return {
          ...current,
          results: {
            ...results,
            users: exists
              ? results.users.map((user) => (user.id === body.user!.id ? body.user! : user))
              : [body.user, ...results.users],
          },
        };
      }
      if (body.team) {
        return {
          ...current,
          results: {
            ...results,
            teams: results.teams.map((team) => (team.id === body.team!.id ? body.team! : team)),
          },
        };
      }
      if (body.pendingGrant) {
        return {
          ...current,
          results: { ...results, pendingGrants: [body.pendingGrant, ...results.pendingGrants] },
        };
      }
      if (action.kind === "pending-revoke") {
        return {
          ...current,
          results: {
            ...results,
            pendingGrants: results.pendingGrants.filter((grant) => grant.id !== action.grant.id),
          },
        };
      }
      return current;
    });
  }

  function openAction(action: PendingAction) {
    setMutation({ kind: "idle" });
    setNotice(null);
    setPending(action);
  }

  const results = search.kind === "results" ? search.results : null;
  const queryLooksLikeEmail = search.kind === "results" && looksLikeEmail(search.query);
  const exactUserForQuery = results?.users.some(
    (user) => user.email && search.kind === "results" &&
      user.email.trim().toLowerCase() === search.query.toLowerCase(),
  );
  const hasAnyResult = results
    ? results.users.length + results.teams.length + results.pendingGrants.length > 0
    : false;

  return (
    <div className="space-y-4">
      <form
        onSubmit={(event) => {
          event.preventDefault();
          setNotice(null);
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

      {notice ? (
        <p className="border border-border bg-code-bg p-3 text-sm" role="status">
          {notice}
        </p>
      ) : null}

      {search.kind === "error" ? (
        <p className="border border-border p-3 text-sm text-muted" role="alert">
          {search.message}
        </p>
      ) : null}

      {results && !hasAnyResult && !queryLooksLikeEmail ? (
        <p className="border border-border p-3 text-sm text-muted">{t("results.empty")}</p>
      ) : null}

      {results && queryLooksLikeEmail && !exactUserForQuery && search.kind === "results" ? (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("emailGrant.title")}</h2>
          <p className="mt-1 max-w-2xl text-muted">
            {t("emailGrant.body", { email: search.query })}
          </p>
          <div className="mt-3 flex flex-wrap gap-1.5">
            <button
              type="button"
              className={buttonClass}
              onClick={() => openAction({ kind: "email-grant", email: search.query, plan: "pro" })}
            >
              {t("actions.grantPro")}
            </button>
            <button
              type="button"
              className={buttonClass}
              onClick={() => openAction({ kind: "email-grant", email: search.query, plan: "founders" })}
            >
              {t("actions.grantFounders")}
            </button>
          </div>
        </section>
      ) : null}

      {results && results.users.length > 0 ? (
        <ResultSection title={t("sections.users", { count: results.users.length })}>
          <table className="w-full min-w-[44rem] text-left text-xs">
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
              {results.users.map((user) => (
                <UserRow key={user.id} user={user} t={t} onAction={openAction} />
              ))}
            </tbody>
          </table>
        </ResultSection>
      ) : null}

      {results && results.teams.length > 0 ? (
        <ResultSection title={t("sections.teams", { count: results.teams.length })}>
          <table className="w-full min-w-[44rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.team")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.access")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.stripe")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.grant")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.actions")}</th>
              </tr>
            </thead>
            <tbody>
              {results.teams.map((team) => (
                <TeamRow key={team.id} team={team} t={t} onAction={openAction} />
              ))}
            </tbody>
          </table>
        </ResultSection>
      ) : null}

      {results && results.pendingGrants.length > 0 ? (
        <ResultSection title={t("sections.pending", { count: results.pendingGrants.length })}>
          <table className="w-full min-w-[36rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.email")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.plan")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.grant")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.actions")}</th>
              </tr>
            </thead>
            <tbody>
              {results.pendingGrants.map((grant) => (
                <PendingRow key={grant.id} grant={grant} t={t} onAction={openAction} />
              ))}
            </tbody>
          </table>
        </ResultSection>
      ) : null}

      <AdminProList
        initialSnapshot={initialSnapshot}
        onPickQuery={(value) => {
          setQuery(value);
          setNotice(null);
          void runSearch(value);
          if (typeof window !== "undefined") window.scrollTo({ top: 0, behavior: "smooth" });
        }}
      />

      <ConfirmDialog
        t={t}
        action={pending}
        mutation={mutation}
        onCancel={() => {
          if (mutation.kind === "saving") return;
          setPending(null);
          setMutation({ kind: "idle" });
        }}
        onConfirm={() => void confirmPending()}
      />
    </div>
  );
}

function ResultSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="mb-1 text-xs font-semibold text-foreground">{title}</h2>
      <div className="overflow-x-auto border border-border">{children}</div>
    </section>
  );
}

function AccessBadge({ active, label }: { active: boolean; label: string }) {
  return (
    <span
      className={`inline-block border px-1.5 py-0.5 font-medium ${
        active ? "border-foreground text-foreground" : "border-border text-muted"
      }`}
    >
      {label}
    </span>
  );
}

function StripeCell({ t, stripe }: { t: Translate; stripe: StripeState }) {
  if (!stripe.subscriptionStatus) return <span className="text-muted">{t("results.noSubscription")}</span>;
  return (
    <span className="text-muted">
      {stripe.subscriptionStatus}
      {stripe.cancelAtPeriodEnd ? ` · ${t("results.cancelling")}` : ""}
    </span>
  );
}

function GrantCell({ t, manualPlanId, lastGrant }: { t: Translate; manualPlanId: string | null; lastGrant: GrantRecord }) {
  const format = useFormatter();
  return (
    <div className="text-muted">
      <div>{manualPlanId ? t("grant.current", { plan: manualPlanId }) : t("grant.none")}</div>
      {lastGrant ? (
        <div className="mt-0.5 text-[10px]">
          {t("grant.by", {
            who: lastGrant.byEmail ?? lastGrant.byUserId,
            when: formatTime(format, lastGrant.at),
          })}
        </div>
      ) : null}
    </div>
  );
}

function UserRow({
  user,
  t,
  onAction,
}: {
  user: AdminUserRow;
  t: Translate;
  onAction: (action: PendingAction) => void;
}) {
  return (
    <tr className="border-b border-border align-top last:border-b-0">
      <td className="px-3 py-2">
        <div className="font-mono text-foreground">{user.email ?? t("results.noEmail")}</div>
        <div className="mt-0.5 text-muted">
          {user.displayName ? `${user.displayName} · ` : ""}
          {user.emailVerified ? t("results.verified") : t("results.unverified")}
        </div>
        <div className="mt-0.5 font-mono text-[10px] text-muted">{user.id}</div>
      </td>
      <td className="px-3 py-2">
        <AccessBadge active={user.isPro} label={user.isPro ? t("access.pro") : t("access.free")} />
      </td>
      <td className="px-3 py-2"><StripeCell t={t} stripe={user.stripe} /></td>
      <td className="px-3 py-2"><GrantCell t={t} manualPlanId={user.manualPlanId} lastGrant={user.lastGrant} /></td>
      <td className="px-3 py-2">
        <div className="flex flex-wrap gap-1.5">
          <button
            type="button"
            disabled={user.manualPlanId === "pro"}
            onClick={() => onAction({ kind: "user-grant", user, plan: "pro" })}
            className={buttonClass}
          >
            {t("actions.grantPro")}
          </button>
          <button
            type="button"
            disabled={user.manualPlanId === "founders"}
            onClick={() => onAction({ kind: "user-grant", user, plan: "founders" })}
            className={buttonClass}
          >
            {t("actions.grantFounders")}
          </button>
          <button
            type="button"
            disabled={user.manualPlanId === null}
            onClick={() => onAction({ kind: "user-grant", user, plan: null })}
            className={dangerButtonClass}
          >
            {t("actions.removeGrant")}
          </button>
          {user.stripe.hasActiveSubscription ? (
            user.stripe.cancelAtPeriodEnd ? (
              <button
                type="button"
                onClick={() => onAction({ kind: "user-subscription", user, action: "resume" })}
                className={buttonClass}
              >
                {t("actions.resumeSubscription")}
              </button>
            ) : (
              <button
                type="button"
                onClick={() => onAction({ kind: "user-subscription", user, action: "cancel" })}
                className={dangerButtonClass}
              >
                {t("actions.downgrade")}
              </button>
            )
          ) : null}
        </div>
      </td>
    </tr>
  );
}

function TeamRow({
  team,
  t,
  onAction,
}: {
  team: AdminTeamRow;
  t: Translate;
  onAction: (action: PendingAction) => void;
}) {
  return (
    <tr className="border-b border-border align-top last:border-b-0">
      <td className="px-3 py-2">
        <div className="text-foreground">{team.displayName}</div>
        <div className="mt-0.5 text-muted">
          {team.memberCount === null
            ? t("results.membersUnknown")
            : t("results.members", { count: team.memberCount })}
        </div>
        <div className="mt-0.5 font-mono text-[10px] text-muted">{team.id}</div>
      </td>
      <td className="px-3 py-2">
        <AccessBadge active={team.isTeam} label={team.isTeam ? t("access.team") : t("access.free")} />
      </td>
      <td className="px-3 py-2"><StripeCell t={t} stripe={team.stripe} /></td>
      <td className="px-3 py-2"><GrantCell t={t} manualPlanId={team.manualPlanId} lastGrant={team.lastGrant} /></td>
      <td className="px-3 py-2">
        <div className="flex flex-wrap gap-1.5">
          <button
            type="button"
            disabled={team.manualPlanId === "team" || team.memberCount === null}
            title={team.memberCount === null ? t("results.membersUnknown") : undefined}
            onClick={() => onAction({ kind: "team-grant", team, plan: "team" })}
            className={buttonClass}
          >
            {t("actions.grantTeam")}
          </button>
          <button
            type="button"
            disabled={team.manualPlanId === null}
            onClick={() => onAction({ kind: "team-grant", team, plan: null })}
            className={dangerButtonClass}
          >
            {t("actions.removeGrant")}
          </button>
          {team.stripe.hasActiveSubscription ? (
            team.stripe.cancelAtPeriodEnd ? (
              <button
                type="button"
                onClick={() => onAction({ kind: "team-subscription", team, action: "resume" })}
                className={buttonClass}
              >
                {t("actions.resumeSubscription")}
              </button>
            ) : (
              <button
                type="button"
                onClick={() => onAction({ kind: "team-subscription", team, action: "cancel" })}
                className={dangerButtonClass}
              >
                {t("actions.downgrade")}
              </button>
            )
          ) : null}
        </div>
      </td>
    </tr>
  );
}

function PendingRow({
  grant,
  t,
  onAction,
}: {
  grant: PendingGrantRow;
  t: Translate;
  onAction: (action: PendingAction) => void;
}) {
  const format = useFormatter();
  return (
    <tr className="border-b border-border align-top last:border-b-0">
      <td className="px-3 py-2 font-mono text-foreground">{grant.email}</td>
      <td className="px-3 py-2 text-muted">{grant.plan}</td>
      <td className="px-3 py-2 text-muted">
        <div>{t("pending.waiting")}</div>
        <div className="mt-0.5 text-[10px]">
          {t("grant.by", { who: grant.grantedByEmail ?? "?", when: formatTime(format, grant.createdAt) })}
        </div>
      </td>
      <td className="px-3 py-2">
        <button
          type="button"
          onClick={() => onAction({ kind: "pending-revoke", grant })}
          className={dangerButtonClass}
        >
          {t("actions.revokePending")}
        </button>
      </td>
    </tr>
  );
}

function ConfirmDialog({
  t,
  action,
  mutation,
  onCancel,
  onConfirm,
}: {
  t: Translate;
  action: PendingAction | null;
  mutation: MutationState;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const copy = action ? confirmCopy(t, action) : null;
  return (
    <Modal open={action !== null} onOpenChange={(open) => { if (!open) onCancel(); }}>
      {copy ? (
        <>
          <Dialog.Title className="text-sm font-medium">{copy.title}</Dialog.Title>
          <Dialog.Description className="mt-2 text-sm text-muted">{copy.body}</Dialog.Description>
          <p className="mt-3 border border-border bg-code-bg px-3 py-2 font-mono text-xs text-foreground">
            {copy.target}
          </p>
          {mutation.kind === "error" ? (
            <p className="mt-3 text-sm text-muted" role="alert">{mutation.message}</p>
          ) : null}
          <div className="mt-5 flex justify-end gap-2">
            <button
              type="button"
              onClick={onCancel}
              disabled={mutation.kind === "saving"}
              className={buttonClass}
            >
              {t("confirm.cancel")}
            </button>
            <button
              type="button"
              onClick={onConfirm}
              disabled={mutation.kind === "saving"}
              className={primaryButtonClass}
            >
              {mutation.kind === "saving" ? t("actions.saving") : copy.confirm}
            </button>
          </div>
        </>
      ) : null}
    </Modal>
  );
}

function confirmCopy(t: Translate, action: PendingAction): {
  title: string;
  body: string;
  target: string;
  confirm: string;
} {
  switch (action.kind) {
    case "user-grant": {
      const target = action.user.email ?? action.user.id;
      if (action.plan === null) {
        return {
          title: t("confirm.removeGrantTitle"),
          body: action.user.stripe.hasActiveSubscription
            ? t("confirm.removeGrantBodyStripe")
            : t("confirm.removeGrantBody"),
          target,
          confirm: t("actions.removeGrant"),
        };
      }
      return {
        title: t("confirm.grantTitle", { plan: planLabel(t, action.plan) }),
        body: t("confirm.grantUserBody", { plan: planLabel(t, action.plan) }),
        target,
        confirm: t("confirm.grant"),
      };
    }
    case "user-subscription":
      return action.action === "cancel"
        ? {
            title: t("confirm.downgradeTitle"),
            body: t("confirm.downgradeBody"),
            target: action.user.email ?? action.user.id,
            confirm: t("actions.downgrade"),
          }
        : {
            title: t("confirm.resumeTitle"),
            body: t("confirm.resumeBody"),
            target: action.user.email ?? action.user.id,
            confirm: t("actions.resumeSubscription"),
          };
    case "team-grant":
      return action.plan === null
        ? {
            title: t("confirm.removeGrantTitle"),
            body: action.team.stripe.hasActiveSubscription
              ? t("confirm.removeGrantBodyStripe")
              : t("confirm.removeTeamGrantBody"),
            target: action.team.displayName,
            confirm: t("actions.removeGrant"),
          }
        : {
            title: t("confirm.grantTitle", { plan: planLabel(t, "team") }),
            body: action.team.memberCount === null
              ? t("confirm.grantTeamBodyUnknown")
              : t("confirm.grantTeamBody", { count: action.team.memberCount }),
            target: action.team.displayName,
            confirm: t("confirm.grant"),
          };
    case "team-subscription":
      return action.action === "cancel"
        ? {
            title: t("confirm.downgradeTitle"),
            body: t("confirm.downgradeTeamBody"),
            target: action.team.displayName,
            confirm: t("actions.downgrade"),
          }
        : {
            title: t("confirm.resumeTitle"),
            body: t("confirm.resumeBody"),
            target: action.team.displayName,
            confirm: t("actions.resumeSubscription"),
          };
    case "email-grant":
      return {
        title: t("confirm.grantTitle", { plan: planLabel(t, action.plan) }),
        body: t("confirm.grantEmailBody", { plan: planLabel(t, action.plan) }),
        target: action.email,
        confirm: t("confirm.grant"),
      };
    case "pending-revoke":
      return {
        title: t("confirm.revokePendingTitle"),
        body: t("confirm.revokePendingBody"),
        target: action.grant.email,
        confirm: t("actions.revokePending"),
      };
  }
}

function successNotice(t: Translate, action: PendingAction): string {
  switch (action.kind) {
    case "user-grant":
      return action.plan === null
        ? t("notices.grantRemoved", { target: action.user.email ?? action.user.id })
        : t("notices.granted", { plan: planLabel(t, action.plan), target: action.user.email ?? action.user.id });
    case "team-grant":
      return action.plan === null
        ? t("notices.grantRemoved", { target: action.team.displayName })
        : t("notices.granted", { plan: planLabel(t, "team"), target: action.team.displayName });
    case "user-subscription":
    case "team-subscription": {
      const target = action.kind === "user-subscription"
        ? action.user.email ?? action.user.id
        : action.team.displayName;
      return action.action === "cancel"
        ? t("notices.downgraded", { target })
        : t("notices.resumed", { target });
    }
    case "email-grant":
      return t("notices.emailGranted", { plan: planLabel(t, action.plan), target: action.email });
    case "pending-revoke":
      return t("notices.pendingRevoked", { target: action.grant.email });
  }
}

function mutationRequest(action: PendingAction): {
  path: string;
  method: "POST" | "DELETE";
  body: Record<string, unknown>;
} {
  switch (action.kind) {
    case "user-grant":
      return { path: "/api/admin/users", method: "POST", body: { userId: action.user.id, plan: action.plan } };
    case "team-grant":
      return { path: "/api/admin/teams", method: "POST", body: { teamId: action.team.id, plan: action.plan } };
    case "user-subscription":
      return {
        path: "/api/admin/subscriptions",
        method: "POST",
        body: { scope: "user", ownerId: action.user.id, action: action.action },
      };
    case "team-subscription":
      return {
        path: "/api/admin/subscriptions",
        method: "POST",
        body: { scope: "team", ownerId: action.team.id, action: action.action },
      };
    case "email-grant":
      return { path: "/api/admin/email-grants", method: "POST", body: { email: action.email, plan: action.plan } };
    case "pending-revoke":
      return { path: "/api/admin/email-grants", method: "DELETE", body: { grantId: action.grant.id } };
  }
}

function planLabel(t: Translate, plan: "pro" | "founders" | "team"): string {
  return t(`plans.${plan}`);
}

function looksLikeEmail(value: string): boolean {
  return /^[^\s@"\\]+@[a-z0-9.-]+\.[a-z]{2,}$/i.test(value.trim());
}

function formatTime(format: ReturnType<typeof useFormatter>, iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return format.dateTime(date, { dateStyle: "medium", timeStyle: "short" });
}

function errorMessage(t: Translate, status: number): string {
  if (status === 401 || status === 403) return t("errors.forbidden");
  if (status === 404) return t("errors.notFound");
  if (status === 409) return t("errors.conflict");
  if (status === 502 || status === 503) return t("errors.billing");
  return t("errors.generic");
}
