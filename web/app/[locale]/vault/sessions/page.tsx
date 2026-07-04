import { desc, eq } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { cloudDb } from "../../../../db/client";
import { vaultSessions } from "../../../../db/schema";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { SiteHeader } from "../../components/site-header";

export const dynamic = "force-dynamic";

export default async function VaultSessionsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "vault.sessions" });

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(signInHref(locale));
  }

  const rows = await cloudDb()
    .select({
      agent: vaultSessions.agent,
      agentSessionId: vaultSessions.agentSessionId,
      cwd: vaultSessions.cwd,
      relPath: vaultSessions.relPath,
      sizeBytes: vaultSessions.sizeBytes,
      lastUploadedAt: vaultSessions.lastUploadedAt,
    })
    .from(vaultSessions)
    .where(eq(vaultSessions.userId, user.id))
    .orderBy(desc(vaultSessions.lastUploadedAt))
    .limit(100);

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto w-full max-w-6xl px-6 py-10">
        <div className="mb-8">
          <p className="text-sm font-medium text-muted">{t("eyebrow")}</p>
          <h1 className="mt-2 text-3xl font-semibold">{t("title")}</h1>
          <p className="mt-3 max-w-2xl text-sm leading-6 text-muted">{t("description")}</p>
        </div>

        {rows.length === 0 ? (
          <div className="border-y border-border py-10">
            <h2 className="text-lg font-medium">{t("emptyTitle")}</h2>
            <p className="mt-2 text-sm text-muted">{t("emptyBody")}</p>
            <code className="mt-4 inline-block rounded-md bg-muted/10 px-3 py-2 font-mono text-sm">
              cmux-vault sync
            </code>
          </div>
        ) : (
          <div className="overflow-x-auto border-y border-border">
            <table className="w-full min-w-[760px] border-collapse text-left text-sm">
              <thead className="text-xs uppercase text-muted">
                <tr>
                  <th className="py-3 pr-4 font-medium">{t("agent")}</th>
                  <th className="py-3 pr-4 font-medium">{t("session")}</th>
                  <th className="py-3 pr-4 font-medium">{t("cwd")}</th>
                  <th className="py-3 pr-4 font-medium">{t("size")}</th>
                  <th className="py-3 font-medium">{t("lastUploaded")}</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={`${row.agent}:${row.agentSessionId}`} className="border-t border-border">
                    <td className="py-3 pr-4 font-mono text-xs">{row.agent}</td>
                    <td className="py-3 pr-4 font-mono text-xs">{truncateSession(row.agentSessionId)}</td>
                    <td className="max-w-md py-3 pr-4 text-muted">
                      <span className="line-clamp-1">{row.cwd || row.relPath || t("unknownCwd")}</span>
                    </td>
                    <td className="py-3 pr-4 tabular-nums">{formatBytes(row.sizeBytes, locale)}</td>
                    <td className="py-3 text-muted">{formatDate(row.lastUploadedAt, locale)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </main>
    </div>
  );
}

function truncateSession(id: string): string {
  return id.length > 18 ? `${id.slice(0, 8)}...${id.slice(-6)}` : id;
}

function formatBytes(bytes: number, locale: string): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${new Intl.NumberFormat(locale, {
    maximumFractionDigits: unitIndex === 0 ? 0 : 1,
  }).format(value)} ${units[unitIndex]}`;
}

function formatDate(date: Date, locale: string): string {
  return new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function signInHref(locale: string): string {
  const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.com");
  afterSignIn.searchParams.set("after_auth_return_to", `/${locale}/vault/sessions`);
  const signIn = new URL("/handler/sign-in", "https://cmux.com");
  signIn.searchParams.set("after_auth_return_to", `${afterSignIn.pathname}${afterSignIn.search}`);
  return `${signIn.pathname}${signIn.search}`;
}
