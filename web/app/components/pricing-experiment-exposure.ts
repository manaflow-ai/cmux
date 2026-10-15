import {
  WEB_PRICING_ASSIGNMENT_COOKIE,
  WEB_PRICING_LIVE_COOKIE,
  WEB_PRICING_PRODUCTION_HOSTS,
} from "../../services/billing/pricingExperiment/webPricingV1";

export type PricingExperimentAssignment = {
  readonly experiment: string;
  readonly variant: string;
};

type ExposureClient = {
  register(properties: Record<string, unknown>): void;
  unregister(property: string): void;
};

const PUBLIC_PRICING_PATH = /^\/pricing\/?$/;

function cookieValue(cookies: string, name: string): string | null {
  for (const part of cookies.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return decodeURIComponent(rest.join("="));
  }
  return null;
}

/**
 * Whether this page view is an exposure: the proxy put this browser in the
 * running experiment (live cookie), pinned it to the variant this page
 * renders, and the visitor is on the public URL. A paused experiment, a bot
 * (no cookies), a non-English page, or a staff preview of `/pricing/<variant>`
 * is never an exposure.
 */
export function pricingExposure(
  assignment: PricingExperimentAssignment,
  location: { readonly cookies: string; readonly pathname: string },
): PricingExperimentAssignment | null {
  if (!PUBLIC_PRICING_PATH.test(location.pathname)) return null;
  if (cookieValue(location.cookies, WEB_PRICING_LIVE_COOKIE) !== "1") return null;
  if (cookieValue(location.cookies, WEB_PRICING_ASSIGNMENT_COOKIE) !== assignment.variant) return null;
  return assignment;
}

/**
 * Tags every later event of this browser with the variant it saw, the same
 * `$feature/<flag>` super property PostHog's own flag calls register. A view
 * that is not an exposure clears it, so a paused experiment stops tagging.
 */
export function syncPricingExperimentProperties(
  client: ExposureClient,
  assignment: PricingExperimentAssignment,
  exposure: PricingExperimentAssignment | null,
): Record<string, string> {
  const flagProperty = `$feature/${assignment.experiment}`;
  if (!exposure) {
    client.unregister(flagProperty);
    client.unregister("pricing_experiment");
    client.unregister("pricing_variant");
    return {};
  }
  const properties = {
    [flagProperty]: exposure.variant,
    pricing_experiment: exposure.experiment,
    pricing_variant: exposure.variant,
  };
  client.register(properties);
  return properties;
}

/**
 * The `$feature_flag_called` exposure, with the properties every paywall
 * experiment records (services/billing/paywall/EXPERIMENTS.md, rule 3).
 * Preview and local deployments report to the same PostHog project, so the
 * channel is what keeps them out of the analysis.
 */
export function exposureEventProperties(
  exposure: PricingExperimentAssignment,
  hostname: string,
): Record<string, string> {
  return {
    $feature_flag: exposure.experiment,
    $feature_flag_response: exposure.variant,
    paywall_experiment: exposure.experiment,
    paywall_variant: exposure.variant,
    paywall_platform: "web",
    paywall_channel: (WEB_PRICING_PRODUCTION_HOSTS as readonly string[]).includes(hostname) ? "production" : "preview",
  };
}
