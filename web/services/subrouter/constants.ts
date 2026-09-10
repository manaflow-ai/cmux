const PRODUCTION_HOSTED_SUBROUTER_URL = "https://sr.cmux.com";
const STAGING_HOSTED_SUBROUTER_URL = "https://staging.sr.cmux.com";

export function defaultHostedSubrouterURL(
  deploymentEnvironment = process.env.VERCEL_ENV,
): string {
  return deploymentEnvironment === "production"
    ? PRODUCTION_HOSTED_SUBROUTER_URL
    : STAGING_HOSTED_SUBROUTER_URL;
}

export function hostedSubrouterBaseURL(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value.trim());
  } catch {
    throw new Error("invalid hosted Subrouter URL");
  }
  if (
    parsed.protocol !== "https:" ||
    parsed.username ||
    parsed.password ||
    parsed.pathname !== "/" ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error("invalid hosted Subrouter URL");
  }
  return parsed.origin;
}
