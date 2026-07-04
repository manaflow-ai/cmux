import { and, desc, eq } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { notFound, redirect } from "next/navigation";
import { cloudDb } from "@/db/client";
import { vaultSessions, vaultSnapshots } from "@/db/schema";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { presignGet } from "@/services/vault/storage";
import { fetchTranscriptPreview, type TranscriptPreview } from "@/services/vault/transcript";
import { formatBytes, formatDate, truncateMiddle } from "@/services/vault/format";
import { CopyButton } from "../../copy-button";

export const dynamic = "force-dynamic";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export default async function VaultSessionDetailPage({
  params,
}: {
  params: Promise<{ locale: string; id: string }>;
}) {
  const { locale, id } = await params;
  const t = await getTranslations({ locale, namespace: "vault.detail" });

  if (!UUID_RE.test(id)) notFound();

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, `/dashboard/vault/sessions/${id}`)));
  }

  const db = cloudDb();
  const [session] = await db
    .select()
    .from(vaultSessions)
    .where(and(eq(vaultSessions.id, id), eq(vaultSessions.userId, user.id)))
    .limit(1);
  if (!session) notFound();

  const snapshots = await db
    .select({
      sha256: vaultSnapshots.sha256,
      sizeBytes: vaultSnapshots.sizeBytes,
      compressedSizeBytes: vaultSnapshots.compressedSizeBytes,
      uploadedAt: vaultSnapshots.uploadedAt,
    })
    .from(vaultSnapshots)
    .where(eq(vaultSnapshots.sessionId, session.id))
    .orderBy(desc(vaultSnapshots.uploadedAt));

  let downloadUrl: string | null = null;
  let preview: TranscriptPreview | null = null;
  try {
    downloadUrl = await presignGet(session.latestObjectKey);
    preview = await fetchTranscriptPreview(downloadUrl);
  } catch {
    preview = null;
  }

  const resumeCommand = `cmux-vault resume ${session.agentSessionId}`;

  return (
    <div className="mx-auto w-full max-w-6xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium uppercase tracking-wide text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium uppercase tracking-wide">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      <section className="border border-border p-3">
        <h2 className="text-sm font-medium uppercase tracking-wide">{t("metadata")}</h2>
        <dl className="mt-3 grid gap-3 md:grid-cols-2">
          <Metadata label={t("agent")} value={session.agent} />
          <Metadata label={t("agentSessionId")} value={session.agentSessionId} />
          <Metadata label={t("cwd")} value={session.cwd ?? t("unknownCwd")} />
          <Metadata label={t("relPath")} value={session.relPath} />
          <Metadata label={t("rawSize")} value={formatBytes(session.sizeBytes, locale)} />
          <Metadata
            label={t("compressedSize")}
            value={session.compressedSizeBytes == null ? t("unknownSize") : formatBytes(session.compressedSizeBytes, locale)}
          />
          <Metadata label={t("firstUploaded")} value={formatDate(session.firstUploadedAt, locale)} />
          <Metadata label={t("lastUploaded")} value={formatDate(session.lastUploadedAt, locale)} />
        </dl>
      </section>

      <section className="border-x border-b border-border p-3">
        <h2 className="text-sm font-medium uppercase tracking-wide">{t("resumeTitle")}</h2>
        <p className="mt-1 text-muted">{t("resumeHint")}</p>
        <div className="mt-3 flex flex-col gap-2 sm:flex-row sm:items-center">
          <code className="block overflow-x-auto border border-border bg-code-bg px-3 py-1.5 font-mono text-xs">
            {resumeCommand}
          </code>
          <CopyButton value={resumeCommand} label={t("copyCommand")} copiedLabel={t("copiedCommand")} />
        </div>
      </section>

      <section className="border-x border-b border-border p-3">
        <h2 className="text-sm font-medium uppercase tracking-wide">{t("downloadTitle")}</h2>
        {downloadUrl ? (
          <>
            <a
              href={downloadUrl}
              rel="nofollow"
              className="mt-3 inline-flex border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
            >
              {t("downloadLink")}
            </a>
            <p className="mt-2 text-muted">{t("downloadExpires")}</p>
          </>
        ) : (
          <p className="mt-2 text-muted">{t("downloadUnavailable")}</p>
        )}
      </section>

      <section className="border-x border-b border-border p-3">
        <h2 className="text-sm font-medium uppercase tracking-wide">{t("snapshotsTitle")}</h2>
        <div className="mt-3 overflow-x-auto border border-border">
          <table className="w-full min-w-[700px] border-collapse text-left">
            <thead className="text-xs uppercase text-muted">
              <tr className="border-b border-border">
                <th className="px-3 py-2 font-medium">{t("sha256")}</th>
                <th className="px-3 py-2 font-medium">{t("rawSize")}</th>
                <th className="px-3 py-2 font-medium">{t("compressedSize")}</th>
                <th className="px-3 py-2 font-medium">{t("uploadedAt")}</th>
              </tr>
            </thead>
            <tbody>
              {snapshots.map((snapshot) => (
                <tr key={snapshot.sha256} className="border-b border-border">
                  <td className="px-3 py-2 font-mono text-xs" title={snapshot.sha256}>
                    {truncateMiddle(snapshot.sha256, 22)}
                  </td>
                  <td className="px-3 py-2 font-mono text-xs tabular-nums">{formatBytes(snapshot.sizeBytes, locale)}</td>
                  <td className="px-3 py-2 font-mono text-xs tabular-nums">{formatBytes(snapshot.compressedSizeBytes, locale)}</td>
                  <td className="px-3 py-2 font-mono text-xs text-muted">{formatDate(snapshot.uploadedAt, locale)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="border-x border-b border-border p-3">
        <h2 className="text-sm font-medium uppercase tracking-wide">{t("transcriptTitle")}</h2>
        {preview ? (
          <>
            <p className="mt-1 text-muted">
              {preview.capped || preview.messageLimitReached
                ? t("previewTruncated", { count: preview.messages.length })
                : t("previewShowing", { count: preview.messages.length })}
            </p>
            <div className="mt-3 max-h-[520px] overflow-auto border border-border">
              {preview.messages.length === 0 ? (
                <p className="p-3 text-muted">{t("previewEmpty")}</p>
              ) : (
                <ul className="divide-y divide-border">
                  {preview.messages.map((message, index) => (
                    <li key={`${message.role}:${index}`} className="grid gap-2 p-3 md:grid-cols-[110px_minmax(0,1fr)]">
                      <div className="font-mono text-xs font-medium uppercase text-muted">
                        {roleLabel(message.role, t)}
                      </div>
                      <div className="whitespace-pre-wrap break-words">
                        {message.text}
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </>
        ) : (
          <p className="mt-2 text-muted">{t("previewUnavailable")}</p>
        )}
      </section>
    </div>
  );
}

function Metadata({
  label,
  value,
}: {
  readonly label: string;
  readonly value: string;
}) {
  return (
    <div>
      <dt className="text-xs uppercase tracking-wide text-muted">{label}</dt>
      <dd className="mt-1 break-words font-mono text-xs">{value}</dd>
    </div>
  );
}

function roleLabel(
  role: string,
  t: (key: "roles.user" | "roles.assistant" | "roles.system" | "roles.tool") => string,
) {
  const normalized = role.toLowerCase();
  if (normalized === "user") return t("roles.user");
  if (normalized === "assistant") return t("roles.assistant");
  if (normalized === "system") return t("roles.system");
  if (normalized === "tool") return t("roles.tool");
  return role.toUpperCase();
}
