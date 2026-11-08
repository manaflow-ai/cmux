import * as Effect from "effect/Effect";
import {
  IROH_RETENTION_MAX_DURATION_MS,
  IROH_RETENTION_MAX_ROWS,
  IrohRepository,
  IrohRepositoryLive,
} from "../../../../../services/iroh/repository";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { authorizeCronRequest } from "../../../../../services/cronAuth";


export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const auth = authorizeCronRequest(request);
  if (!auth.ok && auth.reason === "cron_secret_missing") {
    return jsonResponse({ error: "service_unavailable" }, 503);
  }
  if (!auth.ok) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  try {
    const startedAt = Date.now();
    const retention = await Effect.runPromise(
      Effect.gen(function* () {
        const repository = yield* IrohRepository;
        return yield* repository.pruneExpiredStateGlobally({
          now: new Date(),
          maxRows: IROH_RETENTION_MAX_ROWS,
          maxDurationMs: IROH_RETENTION_MAX_DURATION_MS,
        });
      }).pipe(Effect.provide(IrohRepositoryLive)),
    );
    console.info("iroh retention cleanup completed", {
      rows_processed: retention.rowsProcessed,
      batches: retention.batches,
      backlog: retention.backlog,
      budget_exhausted: retention.budgetExhausted,
      by_category: retention.byCategory,
      duration_ms: Date.now() - startedAt,
    });
    return jsonResponse({ ok: true, retention });
  } catch {
    console.error("iroh retention cleanup failed", { failure: "database" });
    return jsonResponse({ error: "iroh_retention_failed" }, 500);
  }
}
