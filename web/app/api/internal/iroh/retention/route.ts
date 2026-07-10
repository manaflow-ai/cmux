import { timingSafeEqual } from "node:crypto";
import * as Effect from "effect/Effect";
import { IrohRepository, IrohRepositoryLive } from "../../../../../services/iroh/repository";
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
    await Effect.runPromise(
      Effect.gen(function* () {
        const repository = yield* IrohRepository;
        yield* repository.pruneExpiredStateGlobally({ now: new Date() });
      }).pipe(Effect.provide(IrohRepositoryLive)),
    );
    return jsonResponse({ ok: true });
  } catch {
    console.error("iroh retention cleanup failed", { failure: "database" });
    return jsonResponse({ error: "iroh_retention_failed" }, 500);
  }
}
