"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { formatBytes, formatDate } from "@/services/vault/format";
import type { VaultSummary } from "@/services/vault/summary";
import { vaultSummaryQuery } from "../../queries/vault";

/** `/dashboard/vault`: totals across the user's synced transcripts. */
export function VaultOverview() {
  const { data } = useSuspenseQuery(vaultSummaryQuery);
  return <VaultOverviewView summary={data} />;
}

export function VaultOverviewView({ summary }: { readonly summary: VaultSummary }) {
  const t = useTranslations("vault.overview");
  const locale = useLocale();
  const agentCounts = summary.agents
    .map((row) => `${row.sessionCount.toLocaleString(locale)} ${row.agent}`)
    .join(" · ");

  return (
    <div className="mx-auto w-full max-w-6xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      {summary.agents.length === 0 ? (
        <div className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("emptyTitle")}</h2>
          <p className="mt-1 text-muted">{t("emptyBody")}</p>
          <code className="mt-3 inline-block border border-border bg-code-bg px-3 py-1.5 font-mono text-xs">
            cmux-vault sync
          </code>
        </div>
      ) : (
        <>
          <div className="grid border border-border sm:grid-cols-2 lg:grid-cols-4">
            <Metric label={t("totalSessions")} value={summary.sessionCount.toLocaleString(locale)} />
            <Metric label={t("totalRawBytes")} value={formatBytes(summary.rawBytes, locale)} />
            <Metric label={t("totalCompressedBytes")} value={formatBytes(summary.compressedBytes, locale)} />
            <Metric
              label={t("latestUpload")}
              value={summary.lastUploadedAt ? formatDate(summary.lastUploadedAt, locale) : t("never")}
            />
          </div>
          <p className="mt-2 font-mono text-xs text-muted">{agentCounts}</p>
        </>
      )}
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-border p-3 sm:border-r lg:border-b-0">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
    </div>
  );
}
