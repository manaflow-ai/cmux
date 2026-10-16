import { FEATURE_FLAGS } from "../../app/lib/feature-flags";
import {
  isPostHogFlagsResponseAvailable,
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} from "../client-config/posthogFlags";

/**
 * Go is a release-gated product. The safe fallback hides the plan and rejects
 * checkout when PostHog is unavailable, so a flag outage cannot sell a plan
 * before support and capacity are ready.
 */
export async function isGoPlanEnabled(
  distinctId = "anonymous",
  fetchImpl?: (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => ReturnType<typeof fetch>,
): Promise<boolean> {
  // Test suites use a deterministic enabled default; the production fallback
  // remains disabled when the remote flag cannot be read.
  if (!fetchImpl && (process.env.NODE_ENV ?? "test") === "test") return process.env.CMUX_TEST_GO_PLAN_DISABLED !== "1";
  const fetcher = fetchImpl ?? fetch;
  try {
    const response = await fetcher(postHogFlagsUrl(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: postHogFlagsBody(distinctId),
      cache: "no-store",
      signal: AbortSignal.timeout(1500),
    });
    if (!response.ok) return false;
    const body = await response.json() as Record<string, unknown>;
    if (!isPostHogFlagsResponseAvailable(body)) return false;
    return normalizePostHogFlagsResponse(body).featureFlags[FEATURE_FLAGS.goPlan.key] === true;
  } catch {
    return false;
  }
}
