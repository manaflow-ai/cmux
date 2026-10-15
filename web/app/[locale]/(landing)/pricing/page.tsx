import { PricingPage, pricingMetadata } from "./pricing-page";
import { WEB_PRICING_CONTROL_VARIANT } from "../../../../services/billing/pricingExperiment/webPricingV1";

export function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  return pricingMetadata(params);
}

/** `/pricing`: the `web-pricing-v1` control arm, and every visitor outside the experiment. */
export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
}) {
  return PricingPage({ params, searchParams, variant: WEB_PRICING_CONTROL_VARIANT });
}
