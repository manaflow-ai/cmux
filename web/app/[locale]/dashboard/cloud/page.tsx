import { redirect } from "next/navigation";

export const dynamic = "force-dynamic";

export default async function CloudPortalPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  redirect(locale === "en" ? "/home" : `/${locale}/home`);
}
