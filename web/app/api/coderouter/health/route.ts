import { connection } from "next/server";

import { coderouterHealth } from "../../../../services/coderouter/health";
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
  // Never prerendered or cached: every call probes the live dependencies.
  await connection();
  const health = await coderouterHealth();
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
