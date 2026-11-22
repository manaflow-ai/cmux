import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { DashboardApp } from "@/dashboard-app/app";
import { DashboardSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { signInHref } from "@/dashboard-app/lib/session";
import { prefetchDashboard } from "@/dashboard-app/server-prefetch";

type PageProps = {
  readonly params: Promise<{ locale: string; path?: string[] }>;
  readonly searchParams: Promise<Record<string, string | string[] | undefined>>;
};

/**
 * Every dashboard URL. The static shell is the skeleton; the request-time
 * part checks the session (a signed-out visitor is redirected before any SPA
 * code loads) and prefetches the first route's oRPC reads in process, so the
 * SPA hydrates with real data instead of fetching after it boots.
 */
export default function DashboardPage(props: PageProps) {
  return (
    <Suspense fallback={<DashboardSkeleton />}>
      <PrefetchedDashboard {...props} />
    </Suspense>
  );
}

async function PrefetchedDashboard({ params, searchParams }: PageProps) {
  const [{ locale, path = [] }, rawSearch, incoming] = await Promise.all([params, searchParams, headers()]);
  const search: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(rawSearch)) search[key] = Array.isArray(value) ? value[0] : value;
  const dashboardPath = ["/dashboard", ...path.map(encodeURIComponent)].join("/");
  const query = new URLSearchParams(Object.entries(search).filter((entry): entry is [string, string] => entry[1] !== undefined));
  const host = incoming.get("x-forwarded-host") ?? incoming.get("host") ?? "localhost";
  const protocol = incoming.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const request = new Request(`${protocol}://${host}${dashboardPath}`, { headers: incoming });
  const result = await prefetchDashboard(request, dashboardPath, search);
  if (result.kind === "signedOut") {
    redirect(signInHref(locale, `${dashboardPath}${query.size > 0 ? `?${query}` : ""}`));
  }
  return <DashboardApp dehydratedState={result.state} />;
}
