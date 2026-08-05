import { mock } from "bun:test";

import { defaultHostedSubrouterURL } from "../../services/subrouter/constants";

const hostedClientModule = await import(
  "../../services/subrouter/hostedClient"
);
const realCreateHostedSubrouterClient =
  hostedClientModule.createHostedSubrouterClient;
type HostedClientOptions = NonNullable<
  Parameters<typeof realCreateHostedSubrouterClient>[0]
>;

// app/env intentionally snapshots validated configuration at module load. Route
// tests vary hosted Subrouter configuration per case, so pass those values as
// explicit client options instead of depending on process-wide import order.
mock.module("../../services/subrouter/hostedClient", () => ({
  ...hostedClientModule,
  createHostedSubrouterClient: (options: HostedClientOptions = {}) =>
    realCreateHostedSubrouterClient({
      ...options,
      baseUrl:
        options.baseUrl ??
        process.env.SUBROUTER_HOSTED_URL ??
        defaultHostedSubrouterURL(process.env.VERCEL_ENV),
      tenantDeleteToken:
        options.tenantDeleteToken ??
        process.env.SUBROUTER_STACK_TENANT_DELETE_TOKEN ??
        "",
    }),
}));
