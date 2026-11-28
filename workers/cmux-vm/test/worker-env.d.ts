import type { TenantLimitsObject } from "../src/limits/durable-object.ts";
import type { PausedReplicaObject } from "../src/replica/durable-object.ts";

declare global {
  namespace Cloudflare {
    interface Env {
      readonly TENANT_LIMITS: DurableObjectNamespace<TenantLimitsObject>;
      readonly PAUSED_REPLICAS: DurableObjectNamespace<PausedReplicaObject>;
    }
  }
}
