import { timingSafeEqual } from "node:crypto";
import * as Effect from "effect/Effect";
import {
  IrohRepository,
  IrohRepositoryLive,
} from "../../../../../services/iroh/repository";
import { runIrohRetention } from "../../../../../services/iroh/retention";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return handle(request);
}

export async function POST(request: Request): Promise<Response> {
  return handle(request);
}

async function handle(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return jsonResponse({ error: "service_unavailable" }, 503);
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  const token = authorization.toLowerCase().startsWith("bearer ")
    ? authorization.slice("bearer ".length).trim()
    : "";
  const tokenBytes = Buffer.from(token);
  const secretBytes = Buffer.from(secret);
  if (tokenBytes.length !== secretBytes.length || !timingSafeEqual(tokenBytes, secretBytes)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  try {
    const startedAt = Date.now();
    const summary = await Effect.runPromise(
      Effect.gen(function* () {
        const repository = yield* IrohRepository;
        return yield* runIrohRetention({ repository });
      }).pipe(Effect.provide(IrohRepositoryLive)),
    );
    console.info("iroh retention cleanup completed", {
      rows_processed: summary.retention.rowsProcessed,
      batches: summary.retention.batches,
      backlog: summary.retention.backlog,
      budget_exhausted: summary.retention.budgetExhausted,
      by_category: summary.retention.byCategory,
      reap: summary.reap,
      duration_ms: Date.now() - startedAt,
    });
    return jsonResponse({ ok: true, retention: summary.retention, reap: summary.reap });
  } catch {
    console.error("iroh retention cleanup failed", { failure: "database" });
    return jsonResponse({ error: "iroh_retention_failed" }, 500);
  }
}
