import { redirect } from "next/navigation";
import { getPathname } from "@/i18n/navigation";

/** Keep saved device-management links working after the public route rename. */
export default async function LegacyDevicesRedirectPage({
  params,
}: { readonly params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  redirect(getPathname({ locale, href: "/dashboard/mobile-devices" }));
}
