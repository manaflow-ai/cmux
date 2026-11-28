"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useLocale, useTranslations } from "next-intl";
import { Suspense } from "react";
import { formatBytes, formatDate, truncateMiddle } from "@/services/vault/format";
import {
  vaultSessionQuery,
  vaultTranscriptHeadQuery,
  type VaultSessionDetail,
} from "../../queries/vault";
import { vaultSessionRoute } from "../../routes/vault";
import { CopyButton } from "./copy-button";
import { TranscriptViewer } from "./transcript-viewer";

/** `/dashboard/vault/sessions/$id`: metadata panel over the transcript. */
export function VaultSessionScreen() {
  const { id } = vaultSessionRoute.useParams();
  const { data } = useSuspenseQuery(vaultSessionQuery(id));
  const t = useTranslations("vault.detail");
  return (
    <VaultSessionView session={data}>
      <Suspense fallback={<TranscriptLoadingFallback line={t("loadingMessages", { count: 0 })} />}>
        <TranscriptHead sessionId={id} />
      </Suspense>
    </VaultSessionView>
  );
}

function TranscriptHead({ sessionId }: { readonly sessionId: string }) {
  const { data } = useSuspenseQuery(vaultTranscriptHeadQuery(sessionId));
  return (
    <TranscriptViewer
      key={sessionId}
      sessionId={sessionId}
      initialMessages={data.messages}
      complete={data.complete}
    />
  );
}

export function VaultSessionView({
  session,
  children,
}: {
  readonly session: VaultSessionDetail;
  readonly children: React.ReactNode;
}) {
  const t = useTranslations("vault.detail");
  const locale = useLocale();
  const resumeCommand = `cmux-vault resume ${session.agentSessionId}`;
  const cwd = session.cwd ?? t("unknownCwd");

  return (
    <div className="relative h-[calc(100vh-2.75rem)] min-h-0 overflow-hidden bg-background">
      <Link
        to="/dashboard/vault/sessions"
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

              {session.downloadUrl ? (
                <div className="grid gap-2">
                  <a
                    href={session.downloadUrl}
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
                  {t("snapshotsSummary", { count: session.snapshots.length })}
                </summary>
                <div className="border-t border-border">
                  {session.snapshots.map((snapshot) => (
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

      {children}
    </div>
  );
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

function Metadata({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div>
      <div className="text-xs text-muted">{label}</div>
      <div className="mt-1 break-words font-mono text-xs">{value}</div>
    </div>
  );
}
