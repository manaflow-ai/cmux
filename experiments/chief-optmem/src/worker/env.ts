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
  /** Absent on dev and staging until the non-production Freestyle account exists; coding workers then refuse. */
  readonly FREESTYLE_API_KEY?: string;
  /** Freestyle snapshot with Claude Code and Codex installed (from web/services/vms/images/manifest.json). */
  readonly CHIEF_VM_SNAPSHOT?: string;
  /** "1": coding workers run `claude --version` instead of the task (machine and CLI check, no model). */
  readonly CHIEF_CODING_DRY_RUN?: string;
  readonly MEMORY_DO: DurableObjectNamespace<MemoryDO>;
  readonly CHIEF_DO: DurableObjectNamespace<ChiefDO>;
  readonly WORKER_DO: DurableObjectNamespace<WorkerDO>;
}
