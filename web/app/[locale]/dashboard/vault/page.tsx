import { eq, sql } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { cloudDb } from "@/db/client";
import { vaultSessions } from "@/db/schema";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { formatBytes, formatDate } from "@/services/vault/format";

export const dynamic = "force-dynamic";

export default async function VaultOverviewPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "vault.overview" });

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/vault")));
  }

  const rows = await cloudDb()
    .select({
      agent: vaultSessions.agent,
      sessionCount: sql<number>`count(*)::int`,
      rawBytes: sql<number>`coalesce(sum(${vaultSessions.sizeBytes}), 0)::double precision`,
      compressedBytes: sql<number>`coalesce(sum(coalesce(${vaultSessions.compressedSizeBytes}, 0)), 0)::double precision`,
      lastUploadedAt: sql<Date | null>`max(${vaultSessions.lastUploadedAt})`,
    })
    .from(vaultSessions)
    .where(eq(vaultSessions.userId, user.id))
    .groupBy(vaultSessions.agent);

  const totals = rows.reduce(
    (acc, row) => ({
      sessionCount: acc.sessionCount + row.sessionCount,
      rawBytes: acc.rawBytes + row.rawBytes,
      compressedBytes: acc.compressedBytes + row.compressedBytes,
      lastUploadedAt:
        acc.lastUploadedAt && row.lastUploadedAt
          ? acc.lastUploadedAt > row.lastUploadedAt
            ? acc.lastUploadedAt
            : row.lastUploadedAt
          : acc.lastUploadedAt ?? row.lastUploadedAt,
    }),
    {
      sessionCount: 0,
      rawBytes: 0,
      compressedBytes: 0,
      lastUploadedAt: null as Date | null,
    },
  );
  const agentCounts = [...rows]
    .sort((a, b) => b.sessionCount - a.sessionCount)
    .map((row) => `${row.sessionCount.toLocaleString(locale)} ${row.agent}`)
    .join(" · ");

  return (
    <div className="mx-auto w-full max-w-6xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      {rows.length === 0 ? (
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
            <Metric label={t("totalSessions")} value={totals.sessionCount.toLocaleString(locale)} />
            <Metric label={t("totalRawBytes")} value={formatBytes(totals.rawBytes, locale)} />
            <Metric label={t("totalCompressedBytes")} value={formatBytes(totals.compressedBytes, locale)} />
            <Metric
              label={t("latestUpload")}
              value={totals.lastUploadedAt ? formatDate(totals.lastUploadedAt, locale) : t("never")}
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
