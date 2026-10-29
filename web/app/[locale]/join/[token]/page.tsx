import { StackProvider } from "@hexclave/next";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { getTranslations } from "next-intl/server";
import { readJoinViewer } from "@/app/lib/dashboard-auth";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { DashboardQueryProvider } from "@/dashboard-app/components/query-provider";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { JoinInvite } from "./join-invite";
import { joinPageOutcome } from "./join-outcome";

type Params = Promise<{ locale: string; token: string }>;

export const instant = true;

export default function JoinTeamPage({ params }: { params: Params }) {
  return (
    <main className="min-h-screen bg-background px-3 py-16 text-sm text-foreground">
      <Suspense fallback={<DashboardSectionSkeleton variant="cards" />}>
        <JoinSection params={params} />
      </Suspense>
    </main>
  );
}

/** Invite links are shared outside the dashboard, so this page signs visitors in itself. */
async function JoinSection({ params }: { params: Params }) {
  const { locale, token } = await params;
  if (!isStackConfigured()) redirect(`/${locale}`);
  const outcome = joinPageOutcome(await readJoinViewer(), locale, token);
  if (outcome.kind === "sign_in") redirect(outcome.href);
  if (outcome.kind === "retry") return <JoinRetry locale={locale} retryHref={outcome.retryHref} />;
  return (
    <StackProvider app={getStackServerApp()}>
      <DashboardQueryProvider>
        <JoinInvite token={token} viewerEmail={outcome.user.primaryEmail} />
      </DashboardQueryProvider>
    </StackProvider>
  );
}

/** Stack could not confirm the session (throttled or down). Retry the same link. */
async function JoinRetry({ locale, retryHref }: { readonly locale: string; readonly retryHref: string }) {
  const t = await getTranslations({ locale, namespace: "teamInvite" });
  return (
    <div className="mx-auto max-w-md space-y-3">
      <h1 className="text-lg font-semibold">{t("unavailableTitle")}</h1>
      <p className="text-muted-foreground">{t("unavailableBody")}</p>
      <a className="underline" href={retryHref}>{t("retry")}</a>
    </div>
  );
}
