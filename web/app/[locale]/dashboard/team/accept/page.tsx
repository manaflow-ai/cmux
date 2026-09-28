import { Suspense } from "react";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { DashboardAuthRecovery } from "../../components/dashboard-auth-recovery";
import { DashboardSectionSkeleton } from "../../components/dashboard-skeleton";
import { AcceptInvite, acceptReturnPath } from "./accept-invite";

type Params = Promise<{ locale: string }>;
type SearchParams = Promise<{ code?: string | string[] }>;

export const instant = true;

export default function AcceptTeamInvitationPage({
  params,
  searchParams,
}: {
  params: Params;
  searchParams: SearchParams;
}) {
  return (
    <div className="w-full px-3 py-10">
      <Suspense fallback={<DashboardSectionSkeleton variant="cards" />}>
        <AcceptSection params={params} searchParams={searchParams} />
      </Suspense>
    </div>
  );
}

/**
 * Signed-out visitors are sent to sign-in and back here with the code
 * intact (middleware for a missing cookie, `loadDashboardSection` for a
 * session Stack rejects).
 */
async function AcceptSection({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const [{ locale }, query] = await Promise.all([params, searchParams]);
  const code = (Array.isArray(query.code) ? query.code[0] : query.code)?.trim() ?? "";
  const returnPath = acceptReturnPath(code);
  const section = await loadDashboardSection(locale, returnPath);
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath={returnPath} />;
  }
  return <AcceptInvite code={code} viewerEmail={section.user.primaryEmail} />;
}
