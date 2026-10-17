// Staff reads and the kill switch for experiment flags, through PostHog's
// feature-flag API with the server's personal API key. Every call is bounded
// and returns a typed failure instead of throwing, so the Paywall Lab still
// renders the stored optimizer data when PostHog is unreachable.

import { POSTHOG_PROJECT_ID_DEFAULT } from "../paywall/runAll";

const TIMEOUT_MS = 8_000;

export type ExperimentFlagVariant = {
  readonly key: string;
  readonly name: string | null;
  readonly rolloutPercentage: number;
  /** The variant's payload (iOS copy); null when the flag has none. */
  readonly payload: unknown;
};

export type ExperimentFlag = {
  readonly id: number;
  readonly key: string;
  readonly active: boolean;
  readonly variants: readonly ExperimentFlagVariant[];
  /** Whether the flag still has exactly one unfiltered condition group. */
  readonly simpleTargeting: boolean;
};

export type FlagResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: "unconfigured" | "not_found" | "unavailable" };

type Env = Record<string, string | undefined>;
type Fetch = typeof fetch;

function apiConfig(env: Env): { readonly base: string; readonly key: string } | null {
  const key = env.POSTHOG_PERSONAL_API_KEY?.trim();
  // The same project the optimizer reads and writes (runAll.ts).
  const project = env.POSTHOG_PROJECT_ID?.trim() || POSTHOG_PROJECT_ID_DEFAULT;
  if (!key) return null;
  const host = (env.POSTHOG_API_HOST ?? "https://us.posthog.com").replace(/\/$/, "");
  return { base: `${host}/api/projects/${encodeURIComponent(project)}/feature_flags`, key };
}

function parsePayload(value: unknown): unknown {
  if (typeof value !== "string") return value ?? null;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function parseFlag(raw: Record<string, unknown>): ExperimentFlag {
  const filters = (raw.filters ?? {}) as Record<string, unknown>;
  const payloads = (filters.payloads ?? {}) as Record<string, unknown>;
  const groups = Array.isArray(filters.groups) ? filters.groups as Record<string, unknown>[] : [];
  const variants = ((filters.multivariate as { variants?: unknown } | undefined)?.variants);
  return {
    id: Number(raw.id),
    key: String(raw.key),
    active: raw.active === true && raw.deleted !== true,
    simpleTargeting: groups.length === 1 && (!Array.isArray(groups[0]!.properties) || groups[0]!.properties.length === 0),
    variants: Array.isArray(variants)
      ? variants.map((variant: Record<string, unknown>) => ({
          key: String(variant.key ?? ""),
          name: typeof variant.name === "string" ? variant.name : null,
          rolloutPercentage: Number(variant.rollout_percentage ?? 0),
          payload: parsePayload(payloads[String(variant.key ?? "")]),
        }))
      : [],
  };
}

/** The flag named `key`, or a typed failure. */
export async function readExperimentFlag(key: string, env: Env = process.env, fetchImpl: Fetch = fetch): Promise<FlagResult<ExperimentFlag>> {
  const config = apiConfig(env);
  if (!config) return { ok: false, error: "unconfigured" };
  try {
    const response = await fetchImpl(`${config.base}/?search=${encodeURIComponent(key)}&limit=50`, {
      headers: { Authorization: `Bearer ${config.key}` },
      cache: "no-store",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) return { ok: false, error: "unavailable" };
    const body = await response.json() as { results?: unknown };
    const match = Array.isArray(body.results)
      ? (body.results as Record<string, unknown>[]).find((flag) => flag.key === key && flag.deleted !== true)
      : undefined;
    return match ? { ok: true, value: parseFlag(match) } : { ok: false, error: "not_found" };
  } catch {
    return { ok: false, error: "unavailable" };
  }
}

/**
 * The kill switch. An inactive flag serves control to everyone: the web proxy
 * treats it as paused within a minute, and the iOS paywall server must serve
 * its control config. The variants and their allocation are left untouched,
 * so resuming restores the exact split.
 */
export async function setExperimentFlagActive(
  flag: Pick<ExperimentFlag, "id">,
  active: boolean,
  env: Env = process.env,
  fetchImpl: Fetch = fetch,
): Promise<FlagResult<null>> {
  const config = apiConfig(env);
  if (!config) return { ok: false, error: "unconfigured" };
  try {
    const response = await fetchImpl(`${config.base}/${flag.id}/`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${config.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ active }),
      cache: "no-store",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (response.status === 404) return { ok: false, error: "not_found" };
    return response.ok ? { ok: true, value: null } : { ok: false, error: "unavailable" };
  } catch {
    return { ok: false, error: "unavailable" };
  }
}
