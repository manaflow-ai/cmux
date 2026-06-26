import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "../components/site-header";
import { DOWNLOAD_URL } from "../../lib/download";
import { buildAlternates } from "../../../i18n/seo";

// Where the in-app Pro upgrade lives. Install is still the entry point, so the
// Pro CTA points at the download today; swap this for the real checkout URL
// when the billing flow is public.
const PRO_CTA_URL = DOWNLOAD_URL;
const SALES_EMAIL = "founders@manaflow.com";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "pricing" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/pricing"),
  };
}

export default function PricingPage() {
  const t = useTranslations("pricing");

  const freeFeatures = t.raw("free.features") as string[];
  const proFeatures = t.raw("pro.features") as string[];
  const enterpriseFeatures = t.raw("enterprise.features") as string[];
  const compareRows = t.raw("compare.rows") as CompareRow[];
  const sizeRows = t.raw("sizes.rows") as SizeRow[];
  const faqItems = t.raw("faq.items") as { q: string; a: string }[];

  const linkClass =
    "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";

  return (
    <div className="min-h-screen">
      <SiteHeader />

      <main className="w-full max-w-5xl mx-auto px-6 py-16 sm:py-20">
        {/* Title */}
        <h1 className="text-2xl font-medium tracking-tight">{t("title")}</h1>

        {/* Tier cards */}
        <div className="mt-10 grid gap-5 md:grid-cols-3 items-stretch">
          {/* Free */}
          <PlanCard
            name={t("free.name")}
            price={t("free.price")}
            period={t("perMonth")}
          >
            <PrimaryLink href={DOWNLOAD_URL}>{t("free.cta")}</PrimaryLink>
            <p className="mt-5 text-sm font-medium text-muted">
              {t("free.featuresLead")}
            </p>
            <FeatureList items={freeFeatures} muted />
          </PlanCard>

          {/* Pro */}
          <PlanCard
            name={t("pro.name")}
            price={t("pro.price")}
            period={t("perMonth")}
          >
            <PrimaryLink href={PRO_CTA_URL}>{t("pro.cta")}</PrimaryLink>
            <p className="mt-5 text-sm font-medium">{t("pro.featuresLead")}</p>
            <FeatureList items={proFeatures} />
          </PlanCard>

          {/* Enterprise */}
          <PlanCard
            name={t("enterprise.name")}
            price={t("enterprise.price")}
          >
            <SecondaryLink href={`mailto:${SALES_EMAIL}`}>
              {t("enterprise.cta")}
            </SecondaryLink>
            <p className="mt-5 text-sm font-medium">
              {t("enterprise.featuresLead")}
            </p>
            <FeatureList items={enterpriseFeatures} />
          </PlanCard>
        </div>

        {/* Compare plans */}
        <section className="mt-16 border-t border-border pt-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("compare.title")}
          </h2>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full border-collapse text-[15px]">
              <thead>
                <tr className="border-b border-border">
                  <th className="py-3 pr-4 text-left align-bottom font-medium min-w-[12rem]" />
                  <ColumnHead name={t("free.name")} price={t("free.price")} />
                  <ColumnHead
                    name={t("pro.name")}
                    price={`${t("pro.price")}${t("perMonth")}`}
                  />
                  <ColumnHead
                    name={t("enterprise.name")}
                    price={t("enterprise.price")}
                  />
                </tr>
              </thead>
              <tbody>
                {compareRows.map((row, i) => (
                  <tr key={i} className="border-b border-border">
                    <th
                      scope="row"
                      className="py-3 pr-4 text-left font-normal align-top"
                    >
                      {row.label}
                    </th>
                    <CompareCell value={row.free} />
                    <CompareCell value={row.pro} />
                    <CompareCell value={row.enterprise} />
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        {/* Cloud VM sizes */}
        <section className="mt-16 border-t border-border pt-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("sizes.title")}
          </h2>
          <p className="text-[15px] text-muted max-w-2xl">{t("sizes.body")}</p>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full border-collapse text-[15px]">
              <thead>
                <tr className="border-b border-border">
                  <th className="py-3 pr-4 text-left align-bottom font-medium min-w-[10rem]">
                    {t("sizes.colSize")}
                  </th>
                  <th className="px-4 py-3 text-left align-bottom font-medium">
                    {t("sizes.colUse")}
                  </th>
                  <th className="px-4 py-3 text-left align-bottom font-medium whitespace-nowrap">
                    {t("sizes.colRate")}
                  </th>
                </tr>
              </thead>
              <tbody>
                {sizeRows.map((row, i) => (
                  <tr key={i} className="border-b border-border">
                    <th
                      scope="row"
                      className="py-3 pr-4 text-left font-normal align-top whitespace-nowrap"
                    >
                      {row.size}
                    </th>
                    <td className="px-4 py-3 text-left align-top text-muted">
                      {row.use}
                    </td>
                    <td className="px-4 py-3 text-left align-top whitespace-nowrap">
                      {row.rate}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        {/* FAQ */}
        <section className="mt-16 border-t border-border pt-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("faq.title")}
          </h2>
          <div
            className="space-y-5 text-[15px] max-w-2xl"
            style={{ lineHeight: 1.5 }}
          >
            {faqItems.map((item, i) => (
              <div key={i}>
                <p className="font-medium mb-1">{item.q}</p>
                <p className="text-muted">{item.a}</p>
              </div>
            ))}
          </div>
          <p className="mt-8 text-[15px] text-muted">
            {t.rich("help", {
              discord: (chunks) => (
                <a
                  href="https://discord.gg/xsgFEVrWCZ"
                  target="_blank"
                  rel="noopener noreferrer"
                  className={linkClass}
                >
                  {chunks}
                </a>
              ),
              github: (chunks) => (
                <a
                  href="https://github.com/manaflow-ai/cmux"
                  target="_blank"
                  rel="noopener noreferrer"
                  className={linkClass}
                >
                  {chunks}
                </a>
              ),
              email: (chunks) => (
                <a href="mailto:founders@manaflow.ai" className={linkClass}>
                  {chunks}
                </a>
              ),
            })}
          </p>
        </section>
      </main>
    </div>
  );
}

function PlanCard({
  name,
  price,
  period,
  children,
}: {
  name: string;
  price: string;
  period?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex h-full flex-col border border-border p-6">
      <h2 className="text-sm font-medium tracking-tight">{name}</h2>
      <div className="mt-3 flex items-baseline gap-1.5">
        <span className="text-3xl font-medium tracking-tight">{price}</span>
        {period ? <span className="text-sm text-muted">{period}</span> : null}
      </div>
      <div className="mt-6">{children}</div>
    </div>
  );
}

function FeatureList({ items, muted }: { items: string[]; muted?: boolean }) {
  return (
    <ul
      className={`mt-4 space-y-2.5 text-[15px] leading-relaxed ${
        muted ? "text-muted" : ""
      }`}
    >
      {items.map((item, i) => (
        <li key={i} className="flex gap-2.5">
          <CheckIcon />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

function CheckIcon({ inline }: { inline?: boolean }) {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={inline ? "shrink-0" : "mt-1 shrink-0 text-muted"}
      aria-hidden="true"
    >
      <path d="M20 6L9 17l-5-5" />
    </svg>
  );
}

function PrimaryLink({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className="inline-flex w-full items-center justify-center whitespace-nowrap bg-foreground px-5 py-2.5 text-[15px] font-medium hover:opacity-85 transition-opacity"
      style={{ color: "var(--background)", textDecoration: "none" }}
    >
      {children}
    </a>
  );
}

function SecondaryLink({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className="inline-flex w-full items-center justify-center whitespace-nowrap border border-border px-5 py-2.5 text-[15px] font-medium text-foreground hover:bg-code-bg transition-colors"
    >
      {children}
    </a>
  );
}

type CompareRow = {
  label: string;
  free: string;
  pro: string;
  enterprise: string;
};

type SizeRow = {
  size: string;
  use: string;
  rate: string;
};

function ColumnHead({ name, price }: { name: string; price: string }) {
  return (
    <th className="px-4 py-3 text-left align-bottom font-medium">
      {name}
      <span className="block text-xs font-normal text-muted">{price}</span>
    </th>
  );
}

function CompareCell({ value }: { value: string }) {
  const base = "px-4 py-3 text-left align-top";
  if (value === "true") {
    return (
      <td className={base}>
        <span className="inline-flex text-foreground">
          <CheckIcon inline />
        </span>
      </td>
    );
  }
  if (value === "false") {
    return (
      <td className={`${base} text-muted`} aria-label="Not included">
        <span aria-hidden="true">–</span>
      </td>
    );
  }
  return <td className={`${base} text-[13px] text-muted`}>{value}</td>;
}
