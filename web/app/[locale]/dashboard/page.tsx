import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";

export default async function DashboardIndexPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.home" });
  const products = [
    {
      href: "/dashboard/vault",
      name: t("vaultName"),
      description: t("vaultDescription"),
      link: t("vaultLink"),
    },
    {
      href: "/dashboard/subrouter",
      name: t("subrouterName"),
      description: t("subrouterDescription"),
      link: t("subrouterLink"),
    },
  ];

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        {products.map((product) => (
          <section key={product.href} className="border border-border p-3">
            <h2 className="text-sm font-medium">{product.name}</h2>
            <p className="mt-2 text-muted">{product.description}</p>
            <Link
              href={product.href}
              className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
            >
              {product.link}
            </Link>
          </section>
        ))}
      </div>
    </div>
  );
}
