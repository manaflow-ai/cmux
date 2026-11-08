const DIRECT_PORT_MIN = 3800;
const DIRECT_PORT_MAX = 4799;

type Environment = Record<string, string | undefined>;

/**
 * Return the validated public origin for a direct dev-backend instance.
 *
 * This module is intentionally free of Next.js imports so the same validation
 * can run while Next loads next.config.ts and while request middleware runs.
 */
export function directDevBackendOrigin(
  environment: Environment = process.env,
): URL | undefined {
  const transport = environment.CMUX_DEV_BACKEND_TRANSPORT?.trim().toLowerCase();
  if (transport !== "direct") return undefined;

  const configured = environment.CMUX_WWW_ORIGIN?.trim();
  if (!configured) return undefined;

  // The native handoff pins the origin to the owner-provided Tailscale host.
  // Apply the same pin here: without a declared host, fail closed, so the web
  // and native paths trust exactly one backend for auth and billing URLs.
  const trustedHost = environment.CMUX_DEV_BACKEND_TAILSCALE_HOST?.trim().toLowerCase();
  if (!trustedHost) return undefined;

  try {
    const url = new URL(configured);
    const host = url.hostname.toLowerCase();
    const port = url.port ? Number(url.port) : 443;
    if (
      url.protocol !== "https:" ||
      !host.endsWith(".ts.net") ||
      trustedHost !== host ||
      !Number.isInteger(port) ||
      port < DIRECT_PORT_MIN ||
      port > DIRECT_PORT_MAX ||
      url.username ||
      url.password ||
      (url.pathname !== "" && url.pathname !== "/") ||
      url.search ||
      url.hash
    ) {
      return undefined;
    }
    return url;
  } catch {
    return undefined;
  }
}

export function directDevBackendHost(
  environment: Environment = process.env,
): string | undefined {
  return directDevBackendOrigin(environment)?.hostname;
}
