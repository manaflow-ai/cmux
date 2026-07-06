import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import Image from "next/image";
import { buildAlternates } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";

const brandAssets = [
  {
    href: "/brand/app-icon-light.png",
    fileName: "app-icon-light.png",
    format: "PNG 1024 x 1024",
    preview: "light",
    width: 1024,
    height: 1024,
  },
  {
    href: "/brand/app-icon-dark.png",
    fileName: "app-icon-dark.png",
    format: "PNG 1024 x 1024",
    preview: "dark",
    width: 1024,
    height: 1024,
  },
] as const;

const previewClasses = {
  light: "bg-[#f7f7f7] text-[#171717]",
  dark: "bg-[#0a0a0a] text-[#ededed]",
} as const;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "brandAssets" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/assets"),
  };
}

export default function BrandAssetsPage() {
  const t = useTranslations("brandAssets");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("title")} />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <div className="max-w-2xl">
          <h1 className="text-2xl font-semibold tracking-tight mb-2">
            {t("title")}
          </h1>
          <p className="text-muted text-[15px] mb-8" style={{ lineHeight: 1.5 }}>
            {t("description")}
          </p>
        </div>

        <section>
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("iconSection")}
          </h2>
          <div className="grid gap-4 sm:grid-cols-2">
            {brandAssets.map((asset) => (
              <a
                key={asset.href}
                href={asset.href}
                download
                className="group rounded-lg border border-border overflow-hidden hover:bg-code-bg transition-colors"
              >
                <div
                  className={`flex h-56 items-center justify-center p-8 ${previewClasses[asset.preview]}`}
                >
                  <Image
                    src={asset.href}
                    alt={t("assetAlt", { name: asset.fileName })}
                    width={asset.width}
                    height={asset.height}
                    priority={asset.preview === "light"}
                    unoptimized
                    className="h-32 w-32 object-contain"
                  />
                </div>
                <div className="flex items-start justify-between gap-4 p-4">
                  <div className="min-w-0">
                    <h3 className="text-[15px] font-medium">
                      {asset.fileName}
                    </h3>
                    <p className="mt-1 text-sm text-muted">
                      {t(
                        asset.preview === "light"
                          ? "lightPreview"
                          : "darkPreview",
                      )}
                    </p>
                    <p className="mt-3 font-mono text-xs text-muted break-all">
                      {asset.fileName} · {asset.format}
                    </p>
                  </div>
                  <span className="shrink-0 text-xs font-medium text-muted group-hover:text-foreground transition-colors">
                    {t("download")}
                  </span>
                </div>
              </a>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}
