"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { formatBytes, formatDate } from "@/services/vault/format";
import type { VaultSummary } from "@/services/vault/summary";
import { EmptyState } from "../../components/page-states";
import { vaultSummaryQuery } from "../../queries/vault";
import { VaultOverviewFrame } from "./vault-frame";

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
    <VaultOverviewFrame>
      {summary.agents.length === 0 ? (
        <EmptyState
          title={t("emptyTitle")}
          body={t("emptyBody")}
          action={
            <code className="inline-block border border-border bg-code-bg px-3 py-1.5 font-mono text-xs">
              cmux-vault sync
            </code>
          }
        />
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
    </VaultOverviewFrame>
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
