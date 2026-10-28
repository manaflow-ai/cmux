/**
 * The cmux-next Chief pricing page is a proposal. It renders only outside
 * Vercel production (local dev and preview deployments) unless an operator
 * sets CMUX_NEXT_PRICING_PREVIEW=1, so a merge to main cannot publish it.
 */
export function isNextPricingPreviewEnabled(env: Record<string, string | undefined> = process.env): boolean {
  if (env.CMUX_NEXT_PRICING_PREVIEW === "1") return true;
  return env.VERCEL_ENV !== "production";
}
