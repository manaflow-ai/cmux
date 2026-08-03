const PRODUCTION_HOSTED_SUBROUTER_URL = "https://sr.cmux.com";
const STAGING_HOSTED_SUBROUTER_URL = "https://staging.sr.cmux.com";

export function defaultHostedSubrouterURL(
  deploymentEnvironment = process.env.VERCEL_ENV,
): string {
  return deploymentEnvironment === "production"
    ? PRODUCTION_HOSTED_SUBROUTER_URL
    : STAGING_HOSTED_SUBROUTER_URL;
}
