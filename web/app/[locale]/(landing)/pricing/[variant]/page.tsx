import { notFound } from "next/navigation";

import { PricingPage, pricingMetadata } from "../pricing-page";
import {
  WEB_PRICING_VARIANT_ROUTE_KEYS,
  renderableWebPricingVariant,
} from "../../../../../services/billing/pricingExperiment/webPricingV1";

type Params = { locale: string; variant: string };

// One static page per non-control `web-pricing-v1` arm. The proxy rewrites an
// assigned visitor's `/pricing` here, so the variant arrives as server HTML.
// The experiment is English-only; other locales and unknown variants 404.
export async function generateStaticParams({ params }: { params: Promise<{ locale: string }> | { locale: string } }) {
  const { locale } = await params;
  return locale === "en" ? WEB_PRICING_VARIANT_ROUTE_KEYS.map((variant) => ({ variant })) : [];
}

async function variantFor(params: Promise<Params>) {
  const { locale, variant } = await params;
  const found = locale === "en" && WEB_PRICING_VARIANT_ROUTE_KEYS.includes(variant)
    ? renderableWebPricingVariant(variant)
    : null;
  if (!found) notFound();
  return found;
}

export async function generateMetadata({ params }: { params: Promise<Params> }) {
  await variantFor(params);
  return pricingMetadata(params, { variantRoute: true });
}

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
}) {
  const variant = await variantFor(params);
  return (
    <PricingPage
      params={params}
      searchParams={searchParams}
      variant={variant.key}
      presentation={variant.presentation}
    />
  );
}
