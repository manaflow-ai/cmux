import { and, desc, eq } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { notFound, redirect } from "next/navigation";
import { Suspense } from "react";
import { cloudDb } from "@/db/client";
import { vaultSessions, vaultSnapshots } from "@/db/schema";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { presignGet } from "@/services/vault/storage";
import { formatBytes, formatDate, truncateMiddle } from "@/services/vault/format";
import { fetchTranscriptHeadBatch } from "@/services/vault/transcript-head";
import { Link } from "@/i18n/navigation";
import { CopyButton } from "../../copy-button";
import { TranscriptViewer } from "./transcript-viewer";

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
  try {
    downloadUrl = await presignGet(session.latestObjectKey);
  } catch {
    downloadUrl = null;
  }

  const resumeCommand = `cmux-vault resume ${session.agentSessionId}`;
  const cwd = session.cwd ?? t("unknownCwd");

  return (
    <div className="relative h-[calc(100vh-2.75rem)] min-h-0 overflow-hidden bg-background">
      <Link
        href="/dashboard/vault/sessions"
        className="absolute left-4 top-4 z-10 border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
      >
        {t("backToSessions")}
      </Link>

      <aside className="absolute right-4 top-4 z-10 w-80 max-w-[calc(100%-2rem)] border border-border bg-background">
        <details open>
          <summary className="cursor-pointer px-3 py-2 font-medium focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground">
            {t("detailsSummary")}
          </summary>
          <div className="max-h-[calc(100vh-6rem)] overflow-y-auto border-t border-border p-3 font-mono text-xs">
            <div className="grid gap-3">
              <div className="grid gap-2">
                <div className="flex min-w-0 items-center gap-2">
                  <span className="border border-border px-2 py-1 font-mono text-xs font-medium">
                    {session.agent}
                  </span>
                  <span className="min-w-0 truncate font-mono text-xs" title={session.agentSessionId}>
                    {session.agentSessionId}
                  </span>
                </div>
                <CopyButton value={session.agentSessionId} label={t("copySessionId")} copiedLabel={t("copiedSessionId")} />
              </div>

              <Metadata label={t("cwd")} value={cwd} />
              <Metadata label={t("rawSize")} value={formatBytes(session.sizeBytes, locale)} />
              <Metadata
                label={t("compressedSize")}
                value={session.compressedSizeBytes == null ? t("unknownSize") : formatBytes(session.compressedSizeBytes, locale)}
              />
              <Metadata label={t("firstUploaded")} value={formatDate(session.firstUploadedAt, locale)} />
              <Metadata label={t("lastUploaded")} value={formatDate(session.lastUploadedAt, locale)} />

              <div className="grid gap-2">
                <code className="block overflow-x-auto border border-border bg-code-bg px-3 py-1.5 font-mono text-xs">
                  {resumeCommand}
                </code>
                <CopyButton value={resumeCommand} label={t("copyCommand")} copiedLabel={t("copiedCommand")} />
              </div>

              {downloadUrl ? (
                <div className="grid gap-2">
                  <a
                    href={downloadUrl}
                    rel="nofollow"
                    className="border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
                  >
                    {t("downloadLink")}
                  </a>
                  <p className="text-muted">{t("downloadExpires")}</p>
                </div>
              ) : (
                <p className="text-muted">{t("downloadUnavailable")}</p>
              )}

              <details className="border border-border">
                <summary className="cursor-pointer px-3 py-2 font-medium focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground">
                  {t("snapshotsSummary", { count: snapshots.length })}
                </summary>
                <div className="border-t border-border">
                  {snapshots.map((snapshot) => (
                    <div key={snapshot.sha256} className="grid gap-1 border-b border-border p-2">
                      <div className="font-mono text-xs" title={snapshot.sha256}>
                        {truncateMiddle(snapshot.sha256, 22)}
                      </div>
                      <div className="font-mono text-xs text-muted">
                        {formatBytes(snapshot.compressedSizeBytes, locale)} · {formatDate(snapshot.uploadedAt, locale)}
                      </div>
                    </div>
                  ))}
                </div>
              </details>
            </div>
          </div>
        </details>
      </aside>

      <Suspense
        fallback={
          <TranscriptLoadingFallback line={t("loadingMessages", { count: 0 })} />
        }
      >
        <TranscriptHead sessionId={session.id} objectKey={session.latestObjectKey} />
      </Suspense>
    </div>
  );
}

async function TranscriptHead({
  sessionId,
  objectKey,
}: {
  readonly sessionId: string;
  readonly objectKey: string;
}) {
  try {
    const head = await fetchTranscriptHeadBatch(await presignGet(objectKey));
    return (
      <TranscriptViewer
        sessionId={sessionId}
        initialMessages={head.messages}
        complete={head.complete}
      />
    );
  } catch {
    return (
      <TranscriptViewer
        sessionId={sessionId}
        initialMessages={[]}
        complete={false}
      />
    );
  }
}

function TranscriptLoadingFallback({ line }: { readonly line: string }) {
  return (
    <section className="h-full overflow-y-auto">
      <div className="max-w-3xl px-4 pb-16 pt-14">
        <p className="mb-3 text-xs text-muted">{line}</p>
      </div>
    </section>
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
      <div className="text-xs text-muted">{label}</div>
      <div className="mt-1 break-words font-mono text-xs">{value}</div>
    </div>
  );
}
