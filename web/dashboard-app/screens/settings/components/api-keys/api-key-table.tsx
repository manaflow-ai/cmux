"use client";

import { useFormatter, useTranslations } from "next-intl";
import { useState } from "react";
import {
  ActionMenu,
  Badge,
  ConfirmDialog,
  settingsInputClass,
  type BadgeTone,
} from "@/dashboard-app/components/settings-ui";
import {
  API_KEY_STATUSES,
  apiKeyStatus,
  filterApiKeys,
  isEffectivelyNever,
  sortApiKeys,
  type ApiKeyFacts,
  type ApiKeyStatus,
} from "../../lib/api-keys";

/** The key fields the table reads; user and team keys both satisfy it. */
export type ApiKeyRow = ApiKeyFacts & {
  readonly id: string;
  readonly expiresAt?: Date;
  revoke(): Promise<void>;
};

const STATUS_TONE: Record<ApiKeyStatus, BadgeTone> = {
  valid: "outline",
  expired: "muted",
  revoked: "danger",
};

/**
 * Searchable, status-filterable API key list with a guarded revoke action.
 * Reusable for team API keys.
 */
export function ApiKeyTable({ apiKeys }: { readonly apiKeys: readonly ApiKeyRow[] }) {
  const t = useTranslations("dashboard.settings.apiKeys");
  const [search, setSearch] = useState("");
  const [statuses, setStatuses] = useState<ReadonlySet<ApiKeyStatus>>(new Set());
  const [revoking, setRevoking] = useState<ApiKeyRow | null>(null);
  const rows = filterApiKeys(sortApiKeys(apiKeys), search, statuses);

  const toggleStatus = (status: ApiKeyStatus) =>
    setStatuses((current) => {
      const next = new Set(current);
      if (next.has(status)) next.delete(status);
      else next.add(status);
      return next;
    });

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
        <input
          type="search"
          aria-label={t("search")}
          placeholder={t("search")}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          className={`${settingsInputClass} sm:max-w-xs`}
        />
        <div role="group" aria-label={t("statusFilter")} className="flex flex-wrap gap-1">
          {API_KEY_STATUSES.map((status) => (
            <button
              key={status}
              type="button"
              aria-pressed={statuses.has(status)}
              onClick={() => toggleStatus(status)}
              className={`border px-2 py-1 text-xs ${
                statuses.has(status)
                  ? "border-foreground bg-foreground text-background"
                  : "border-border text-muted hover:text-foreground"
              }`}
            >
              {t(`status.${status}`)}
            </button>
          ))}
        </div>
      </div>
      {rows.length === 0 ? (
        <p className="border border-border p-4 text-center text-muted">
          {apiKeys.length === 0 ? t("empty") : t("noMatches")}
        </p>
      ) : (
        <ApiKeyList rows={rows} onRevoke={setRevoking} />
      )}
      <ConfirmDialog
        open={revoking !== null}
        onOpenChange={(open) => {
          if (!open) setRevoking(null);
        }}
        title={t("revokeTitle")}
        description={t("revokeBody", { lastFour: revoking?.value.lastFour ?? "" })}
        acknowledgement={t("revokeAcknowledge")}
        typedConfirmation={revoking?.value.lastFour}
        confirmLabel={t("revokeConfirm")}
        errorMessage={t("revokeError")}
        onConfirm={async () => {
          await revoking?.revoke();
        }}
      />
    </div>
  );
}

function ApiKeyList({
  rows,
  onRevoke,
}: {
  readonly rows: readonly ApiKeyRow[];
  readonly onRevoke: (row: ApiKeyRow) => void;
}) {
  const t = useTranslations("dashboard.settings.apiKeys");
  return (
    <div className="border border-border">
      <div className="hidden grid-cols-[1.5fr_0.8fr_0.8fr_1fr_1fr_2rem] gap-3 border-b border-border px-3 py-2 text-xs text-muted md:grid">
        <span>{t("columns.description")}</span>
        <span>{t("columns.status")}</span>
        <span>{t("columns.key")}</span>
        <span>{t("columns.expiresAt")}</span>
        <span>{t("columns.createdAt")}</span>
        <span />
      </div>
      <ul className="divide-y divide-border">
        {rows.map((row) => (
          <ApiKeyListRow key={row.id} row={row} onRevoke={onRevoke} />
        ))}
      </ul>
    </div>
  );
}

function ApiKeyListRow({
  row,
  onRevoke,
}: {
  readonly row: ApiKeyRow;
  readonly onRevoke: (row: ApiKeyRow) => void;
}) {
  const t = useTranslations("dashboard.settings.apiKeys");
  const format = useFormatter();
  const status = apiKeyStatus(row);
  const expires =
    status === "revoked"
      ? "—"
      : isEffectivelyNever(row.expiresAt)
        ? t("never")
        : format.dateTime(row.expiresAt as Date, { dateStyle: "medium" });

  return (
    <li className="grid grid-cols-[minmax(0,1fr)_2rem] gap-x-3 gap-y-1 px-3 py-2 md:grid-cols-[1.5fr_0.8fr_0.8fr_1fr_1fr_2rem] md:items-center">
      <span className="min-w-0 truncate font-medium">{row.description}</span>
      <div className="col-start-2 row-start-1 flex justify-end md:col-start-6">
        {status === "valid" ? (
          <ActionMenu
            label={t("actionsLabel", { description: row.description })}
            items={[{ id: "revoke", label: t("revoke"), danger: true, onSelect: () => onRevoke(row) }]}
          />
        ) : null}
      </div>
      <span className="col-start-1 md:col-start-auto">
        <Badge tone={STATUS_TONE[status]}>{t(`status.${status}`)}</Badge>
      </span>
      <span className="col-start-1 font-mono text-xs md:col-start-auto">*******{row.value.lastFour}</span>
      <span className="col-start-1 text-xs md:col-start-auto md:text-sm">
        <span className="text-muted md:hidden">{t("columns.expiresAt")}: </span>
        {expires}
      </span>
      <span className="col-start-1 text-xs md:col-start-auto md:text-sm">
        <span className="text-muted md:hidden">{t("columns.createdAt")}: </span>
        {format.dateTime(row.createdAt, { dateStyle: "medium" })}
      </span>
    </li>
  );
}
