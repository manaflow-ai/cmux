"use client";

import { Link, type LinkProps } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { shellRoute } from "../../routes/root";

type Product = {
  readonly to: NonNullable<LinkProps["to"]>;
  readonly name: string;
  readonly description: string;
  readonly link: string;
};

/** `/dashboard`: the product overview. It lists products and no private data. */
export function HomeScreen() {
  const { session } = shellRoute.useRouteContext();
  return <HomeView vaultEnabled={session.flags.vaultEnabled} />;
}

export function HomeView({ vaultEnabled }: { readonly vaultEnabled: boolean }) {
  const t = useTranslations("dashboard.home");
  const products: Product[] = [
    {
      to: "/dashboard/cloud",
      name: t("cloudName"),
      description: t("cloudDescription"),
      link: t("cloudLink"),
    },
    {
      to: "/dashboard/coderouter",
      name: t("coderouterName"),
      description: t("coderouterDescription"),
      link: t("coderouterLink"),
    },
    {
      to: "/dashboard/testflight",
      name: t("iosAppName"),
      description: t("iosAppDescription"),
      link: t("iosLink"),
    },
  ];
  if (vaultEnabled) {
    products.unshift({
      to: "/dashboard/vault",
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
          <section key={product.to} className="border border-border p-3">
            <h2 className="text-sm font-medium">{product.name}</h2>
            <p className="mt-2 text-muted">{product.description}</p>
            <Link
              to={product.to}
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
