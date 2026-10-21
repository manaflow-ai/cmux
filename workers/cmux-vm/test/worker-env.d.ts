import type { TenantLimitsObject } from "../src/limits/durable-object.ts";

declare global {
  namespace Cloudflare {
    interface Env {
      readonly TENANT_LIMITS: DurableObjectNamespace<TenantLimitsObject>;
    }
  }
}
