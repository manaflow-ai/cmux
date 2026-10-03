import type { MemoryDO } from "./memory-do.ts";

export interface Env {
  readonly ENVIRONMENT: string;
  /** Bearer token for every /v1 route (experiment only; a wrangler secret on staging). */
  readonly CHIEF_TOKEN: string;
  readonly MEMORY_DO: DurableObjectNamespace<MemoryDO>;
}
