import { connection } from "next/server";

import {
  coderouterHealth,
  createCachedCoderouterHealthProbe,
} from "../../../../services/coderouter/health";
import {
  coderouterControlRoute,
  recordCoderouterOutcome,
} from "../../../../services/coderouter/requestTelemetry";

/**
 * Dependency health for uptime monitors and the alert cron. Unauthenticated
 * and value-free: statuses, latencies and short reasons only. 200 when the
 * data plane can route, 503 when a critical dependency is down.
 */
export const GET = coderouterControlRoute("health", "/api/coderouter/health", async () => {
  // Never prerendered. The short, in-process cache and shared promise prevent
  // an unauthenticated monitor retry burst from multiplying DB load.
  await connection();
  const health = await cachedCoderouterHealth();
  const status = health.status === "down" ? 503 : 200;
  // A failing probe is an operator fault, but its own fingerprint: one
  // PostHog issue per outage instead of a generic server_error.
  recordCoderouterOutcome({
    outcome: health.status === "down" ? "dependency_down" : "success",
    failureStage: health.status === "down" ? "health" : "none",
    status,
  });
  return Response.json(health, {
    status,
    headers: { "cache-control": "no-store" },
  });
});

const cachedCoderouterHealth = createCachedCoderouterHealthProbe(coderouterHealth);
