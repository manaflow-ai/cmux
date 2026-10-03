import type { ChiefDO } from "./chief-do.ts";
import type { MemoryDO } from "./memory-do.ts";
import type { WorkerDO } from "./worker-do.ts";

export interface Env {
  readonly ENVIRONMENT: string;
  /** Bearer token for every /v1 route (experiment only; a wrangler secret on staging). */
  readonly CHIEF_TOKEN: string;
  /** pi-ai model ids through the AI binding: `@cf/...` (Workers AI) or `<vendor>/<id>` (AI Gateway). */
  readonly CHIEF_MODEL: string;
  readonly WORKER_MODEL: string;
  readonly AI: Ai;
  readonly MEMORY_DO: DurableObjectNamespace<MemoryDO>;
  readonly CHIEF_DO: DurableObjectNamespace<ChiefDO>;
  readonly WORKER_DO: DurableObjectNamespace<WorkerDO>;
}
