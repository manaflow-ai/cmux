import { redirect } from "next/navigation";
import { isStackConfigured } from "@/app/lib/stack";
import { TeamHashRedirect } from "./team-redirect";

export const instant = true;

/**
 * Legacy Hexclave account settings URL. Stack emails and old bookmarks still
 * link here with a hash; the client maps it to `/dashboard/settings/*` or
 * `/dashboard/teams/*`. Each destination runs its own session gate.
 */
export default async function DashboardTeamPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) {
    redirect(`/${locale}`);
  }
  return <TeamHashRedirect />;
}
