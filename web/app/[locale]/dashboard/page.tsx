import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { Link } from "@/i18n/navigation";
import { isStackConfigured } from "@/app/lib/stack";
import { isVaultEnabled } from "@/services/vault/config";

// The overview lists products only. It carries no private data, so it is
// part of the static shell; the layout's session guard still redirects a
// rejected session to sign-in.
export const instant = true;

export default async function DashboardIndexPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;

  if (!isStackConfigured()) {
    redirect("/");
  }

  const t = await getTranslations({ locale, namespace: "dashboard.home" });
  const products = [
    {
      href: "/dashboard/cloud",
      name: t("cloudName"),
      description: t("cloudDescription"),
      link: t("cloudLink"),
    },
    {
      href: "/dashboard/coderouter",
      name: t("coderouterName"),
      description: t("coderouterDescription"),
      link: t("coderouterLink"),
    },
    {
      href: "/dashboard/testflight",
      name: t("iosAppName"),
      description: t("iosAppDescription"),
      link: t("iosLink"),
    },
  ];
  if (isVaultEnabled()) {
    products.unshift({
      href: "/dashboard/vault",
      name: t("vaultName"),
      description: t("vaultDescription"),
      link: t("vaultLink"),
    });
  }

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
