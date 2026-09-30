"use client";

import { useUser } from "@hexclave/next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useFormatter, useNow, useTranslations } from "next-intl";
import { useState } from "react";
import {
  ActionMenu,
  Badge,
  ConfirmDialog,
  InlineError,
  SettingsPanel,
  settingsButtonClass,
  useAsyncAction,
} from "@/dashboard-app/components/settings-ui";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { type SettingsSession, settingsSessionsQuery } from "@/dashboard-app/queries/settings";

/** A session with its timestamps as dates, for formatting. */
export type ActiveSession = Omit<SettingsSession, "createdAt" | "lastUsedAt"> & {
  readonly createdAt: Date;
  readonly lastUsedAt: Date | null;
};

function withDates(session: SettingsSession): ActiveSession {
  return {
    ...session,
    createdAt: new Date(session.createdAt),
    lastUsedAt: session.lastUsedAt ? new Date(session.lastUsedAt) : null,
  };
}

/** Remove one session from a list (optimistic revoke). */
export function withoutSession<Session extends { readonly id: string }>(
  sessions: readonly Session[] | undefined,
  sessionId: string,
): Session[] {
  return (sessions ?? []).filter((session) => session.id !== sessionId);
}

/** `/dashboard/settings/sessions`: active sessions with revoke actions. */
export function SessionSettings() {
  const t = useTranslations("dashboard.settings.sessions");
  const user = useUser({ or: "redirect" });
  const queryClient = useQueryClient();
  const queryKey = settingsSessionsQuery.queryKey;
  const sessions = useQuery({ ...settingsSessionsQuery, select: (list) => list.map(withDates) });
  const [confirmingAll, setConfirmingAll] = useState(false);
  const [runRevoke, revokeState] = useAsyncAction(t("revokeError"));
  const others = (sessions.data ?? []).filter((session) => !session.isCurrentSession);

  const revoke = (sessionId: string) =>
    runRevoke(async () => {
      const previous = queryClient.getQueryData(queryKey);
      queryClient.setQueryData(queryKey, (current) => withoutSession(current, sessionId));
      try {
        await user.revokeSession(sessionId);
      } catch (error) {
        queryClient.setQueryData(queryKey, previous);
        throw error;
      }
    });

  const revokeAllOthers = async () => {
    const targets = others.map((session) => session.id);
    try {
      await Promise.all(targets.map((id) => user.revokeSession(id)));
    } finally {
      // Refetch either way: a partial failure leaves some sessions revoked.
      await queryClient.invalidateQueries({ queryKey });
    }
  };

  return (
    <SettingsPanel
      title={t("heading")}
      description={t("explanation")}
      actions={
        others.length > 0 ? (
          <button type="button" onClick={() => setConfirmingAll(true)} className={settingsButtonClass("secondary", "sm")}>
            {t("revokeAll")}
          </button>
        ) : null
      }
    >
      {sessions.isPending ? (
        <DashboardSectionSkeleton variant="rows" />
      ) : sessions.isError ? (
        <InlineError message={t("loadError")} />
      ) : (
        <SessionList sessions={sessions.data} pending={revokeState.pending} onRevoke={(id) => void revoke(id)} />
      )}
      <InlineError message={revokeState.error} />
      <ConfirmDialog
        open={confirmingAll}
        onOpenChange={setConfirmingAll}
        title={t("revokeAllTitle")}
        description={t("revokeAllBody", { count: others.length })}
        confirmLabel={t("revokeAllConfirm")}
        errorMessage={t("revokeAllError")}
        onConfirm={revokeAllOthers}
      />
    </SettingsPanel>
  );
}

function SessionList({
  sessions,
  pending,
  onRevoke,
}: {
  readonly sessions: readonly ActiveSession[];
  readonly pending: boolean;
  readonly onRevoke: (sessionId: string) => void;
}) {
  const t = useTranslations("dashboard.settings.sessions");
  if (sessions.length === 0) {
    return <p className="border border-border p-4 text-center text-muted">{t("empty")}</p>;
  }
  return (
    <div className="border border-border">
      <div className="hidden grid-cols-[1.4fr_1fr_1fr_1fr_2rem] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
        <span>{t("columns.session")}</span>
        <span>{t("columns.ip")}</span>
        <span>{t("columns.location")}</span>
        <span>{t("columns.lastUsed")}</span>
        <span />
      </div>
      <ul className="divide-y divide-border">
        {sessions.map((session) => (
          <SessionRow key={session.id} session={session} pending={pending} onRevoke={onRevoke} />
        ))}
      </ul>
    </div>
  );
}

function SessionRow({
  session,
  pending,
  onRevoke,
}: {
  readonly session: ActiveSession;
  readonly pending: boolean;
  readonly onRevoke: (sessionId: string) => void;
}) {
  const t = useTranslations("dashboard.settings.sessions");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });
  const lastUsed = session.lastUsedAt;

  return (
    <li className="grid grid-cols-[minmax(0,1fr)_2rem] gap-x-3 gap-y-1 px-3 py-2 md:grid-cols-[1.4fr_1fr_1fr_1fr_2rem] md:items-center">
      <div className="flex min-w-0 flex-col gap-1">
        <span className="font-medium">{session.isCurrentSession ? t("current") : t("other")}</span>
        {session.isImpersonation ? <Badge tone="muted">{t("impersonation")}</Badge> : null}
        <span className="text-xs text-muted">
          {t("signedIn", { date: format.dateTime(session.createdAt, { dateStyle: "medium" }) })}
        </span>
      </div>
      <div className="col-start-2 row-start-1 flex justify-end md:col-start-5">
        <ActionMenu
          label={t("actionsLabel")}
          disabled={pending}
          items={[
            {
              id: "revoke",
              label: t("revoke"),
              danger: true,
              onSelect: () => onRevoke(session.id),
              disabled: session.isCurrentSession,
              disabledReason: session.isCurrentSession ? t("cannotRevokeCurrent") : undefined,
            },
          ]}
        />
      </div>
      <SessionCell label={t("columns.ip")} value={session.geoInfo?.ip || t("unknownIp")} />
      <SessionCell label={t("columns.location")} value={session.geoInfo?.cityName || t("unknownLocation")} />
      <div className="col-start-1 text-xs md:col-start-auto md:text-sm">
        <span className="text-muted md:hidden">{t("columns.lastUsed")}: </span>
        {lastUsed ? (
          <span title={format.dateTime(lastUsed, { dateStyle: "medium", timeStyle: "short" })}>
            {format.relativeTime(lastUsed, now)}
            <span className="block text-xs text-muted">{format.dateTime(lastUsed, { dateStyle: "medium" })}</span>
          </span>
        ) : (
          t("never")
        )}
      </div>
    </li>
  );
}

function SessionCell({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div className="col-start-1 min-w-0 truncate text-xs md:col-start-auto md:text-sm">
      <span className="text-muted md:hidden">{label}: </span>
      {value}
    </div>
  );
}
