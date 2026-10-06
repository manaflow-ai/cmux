"use client";

import { useLocale } from "next-intl";
import { formatBillingDate } from "@/dashboard-app/screens/billing/billing-format";
import { pricingActionClassName } from "./pricing-shared";

/**
 * The current plan's card after a cancel: the day access ends (Stripe's
 * date, shown in the viewer's time zone like the dashboard) and Resubscribe,
 * which undoes the cancel through the same form action the billing screen
 * uses. Labels come from the server catalog; `{date}` is filled here.
 */
export function PricingResubscribe({
  endsAt,
  endsOnLabel,
  endsSoonLabel,
  resubscribeLabel,
}: {
  readonly endsAt: string | null;
  /** "Ends on {date}". */
  readonly endsOnLabel: string;
  /** Shown when Stripe sent no end date. */
  readonly endsSoonLabel: string;
  readonly resubscribeLabel: string;
}) {
  const locale = useLocale();
  const date = formatBillingDate(endsAt, locale);
  return (
    <form method="post" action="/api/billing/subscription" className="space-y-2" data-testid="pricing-resubscribe">
      <input type="hidden" name="action" value="resume" />
      {/* The primary action's text color comes from the style, as on PrimaryLink. */}
      <button
        type="submit"
        className={pricingActionClassName("primary")}
        style={{ color: "var(--button-foreground, var(--background))" }}
      >
        {resubscribeLabel}
      </button>
      {/* The server renders in its own time zone; the viewer's date replaces it. */}
      <p className="text-sm text-muted" suppressHydrationWarning>
        {date ? endsOnLabel.replace("{date}", date) : endsSoonLabel}
      </p>
    </form>
  );
}
