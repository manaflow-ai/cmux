import { redirect } from "next/navigation";
import { getPathname } from "@/i18n/navigation";

// redirect so existing links and bookmarks (including ?team=…) still resolve.
export default async function AiAccountsRedirectPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
}) {
  const [{ locale }, { team: teamParam }] = await Promise.all([params, searchParams]);
  const team = Array.isArray(teamParam) ? teamParam[0] : teamParam;
  const target = getPathname({
    locale,
    href: {
      pathname: "/dashboard/coderouter",
      query: team ? { team } : undefined,
    },
  });
  redirect(target);
}
