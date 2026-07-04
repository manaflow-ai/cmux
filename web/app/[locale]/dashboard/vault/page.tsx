import { eq, sql } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { cloudDb } from "@/db/client";
import { vaultSessions } from "@/db/schema";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { Link } from "@/i18n/navigation";
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

  return (
    <div className="mx-auto w-full max-w-6xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium uppercase tracking-wide text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium uppercase tracking-wide">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      {rows.length === 0 ? (
        <div className="border border-border p-3">
          <h2 className="text-sm font-medium uppercase tracking-wide">{t("emptyTitle")}</h2>
          <p className="mt-1 text-muted">{t("emptyBody")}</p>
          <code className="mt-3 inline-block border border-border bg-code-bg px-3 py-1.5 font-mono text-xs">
            cmux-vault sync
          </code>
        </div>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Metric label={t("totalSessions")} value={totals.sessionCount.toLocaleString(locale)} />
            <Metric label={t("totalRawBytes")} value={formatBytes(totals.rawBytes, locale)} />
            <Metric label={t("totalCompressedBytes")} value={formatBytes(totals.compressedBytes, locale)} />
            <Metric
              label={t("latestUpload")}
              value={totals.lastUploadedAt ? formatDate(totals.lastUploadedAt, locale) : t("never")}
            />
          </div>

          <div className="mt-8 grid gap-4 lg:grid-cols-3">
            {rows.map((row) => (
              <Link
                key={row.agent}
                href={`/dashboard/vault/sessions?agent=${row.agent}`}
                className="group border border-border p-3 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
              >
                <div className="flex items-center justify-between gap-3">
                  <h2 className="font-mono text-xs font-medium uppercase">{row.agent}</h2>
                  <span className="border border-border px-2 py-1 font-mono text-xs uppercase text-muted group-hover:text-background">
                    {t("sessionsCount", { count: row.sessionCount })}
                  </span>
                </div>
                <dl className="mt-4 grid gap-2 text-xs">
                  <div>
                    <dt className="text-muted group-hover:text-background">{t("rawBytes")}</dt>
                    <dd className="mt-1 font-mono tabular-nums">{formatBytes(row.rawBytes, locale)}</dd>
                  </div>
                  <div>
                    <dt className="text-muted group-hover:text-background">{t("compressedBytes")}</dt>
                    <dd className="mt-1 font-mono tabular-nums">{formatBytes(row.compressedBytes, locale)}</dd>
                  </div>
                  <div>
                    <dt className="text-muted group-hover:text-background">{t("lastUpload")}</dt>
                    <dd className="mt-1 font-mono">
                      {row.lastUploadedAt ? formatDate(row.lastUploadedAt, locale) : t("never")}
                    </dd>
                  </div>
                </dl>
              </Link>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="border border-border p-3">
      <p className="text-xs uppercase tracking-wide text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
    </div>
  );
}
