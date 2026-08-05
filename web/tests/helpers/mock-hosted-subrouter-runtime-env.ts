import { defaultHostedSubrouterURL } from "../../services/subrouter/constants";
import { createHostedSubrouterClient } from "../../services/subrouter/hostedClient";
type HostedClientOptions = NonNullable<
  Parameters<typeof createHostedSubrouterClient>[0]
>;

// app/env intentionally snapshots validated configuration at module load. Route
// tests vary hosted Subrouter configuration per case, so pass those values as
// explicit client options instead of depending on process-wide import order.
export function createRuntimeEnvHostedSubrouterClient(
  options: HostedClientOptions = {},
) {
  return createHostedSubrouterClient({
    ...options,
    baseUrl:
      options.baseUrl ??
      process.env.SUBROUTER_HOSTED_URL ??
      defaultHostedSubrouterURL(process.env.VERCEL_ENV),
    tenantDeleteToken:
      options.tenantDeleteToken ??
      process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN ??
      "",
  });
}
