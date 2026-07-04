import { getTranslations } from "next-intl/server";

export default async function SubrouterOverviewPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.subrouter" });

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      <section className="border border-border p-3">
        <h2 className="text-sm font-medium">{t("comingSoonTitle")}</h2>
        <p className="mt-1 text-muted">{t("comingSoonBody")}</p>
      </section>
    </div>
  );
}
