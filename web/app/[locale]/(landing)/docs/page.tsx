import { redirect } from "next/navigation";

export default async function DocsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const prefix = locale === "en" ? "" : `/${locale}`;
  redirect(`${prefix}/docs/getting-started`);
}
