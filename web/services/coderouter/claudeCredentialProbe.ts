// Live check of a Claude upstream credential before it is stored, so a dead
// key or a revoked token is refused at add time instead of failing the first
// machine that lands on it. The probe is the cheapest authenticated call each
// upstream has: `count_tokens` (free, no completion) for Anthropic and
// Bedrock. Only 401/403 mean "rejected"; any other answer proves the
// credential authenticated. A network failure is reported as unreachable so
// the caller can decide to store anyway rather than block on Anthropic's
// availability.
//
// For a Claude Code token the profile endpoint also yields the account email,
// which becomes the default label so a team can tell its tokens apart.
import { signAwsRequest } from "./awsSigV4";
import { bedrockRuntimeUrl } from "./bedrock";
import type { ClaudeUpstreamInput } from "./claudeUpstream";

export const ANTHROPIC_API = "https://api.anthropic.com";
const OAUTH_BETA = "oauth-2025-04-20";
const PROBE_MODEL = "claude-haiku-4-5-20251001";
const BEDROCK_PROBE_MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0";
const PROBE_TIMEOUT_MS = 8_000;

export type CredentialProbeResult =
  | { readonly ok: true; readonly email: string | null }
  | { readonly ok: false; readonly reason: "rejected"; readonly status: number; readonly message: string }
  | { readonly ok: false; readonly reason: "unreachable"; readonly message: string };

export type CredentialProbeDependencies = {
  readonly fetch: typeof fetch;
  readonly now: () => Date;
};

const defaultDependencies: CredentialProbeDependencies = {
  fetch: (input, init) => fetch(input, init),
  now: () => new Date(),
};

export async function probeClaudeCredential(
  input: ClaudeUpstreamInput,
  dependencies: CredentialProbeDependencies = defaultDependencies,
): Promise<CredentialProbeResult> {
  try {
    switch (input.kind) {
      case "anthropic_api_key":
        return await anthropicProbe(dependencies, { "x-api-key": input.apiKey }, null);
      case "anthropic_oauth":
        return await anthropicProbe(
          dependencies,
          { authorization: `Bearer ${input.token}`, "anthropic-beta": OAUTH_BETA },
          input.token,
        );
      case "bedrock":
        return await bedrockProbe(dependencies, input);
    }
  } catch (error) {
    return { ok: false, reason: "unreachable", message: error instanceof Error ? error.message : String(error) };
  }
}

async function anthropicProbe(
  dependencies: CredentialProbeDependencies,
  credentialHeaders: Record<string, string>,
  oauthToken: string | null,
): Promise<CredentialProbeResult> {
  const response = await dependencies.fetch(`${ANTHROPIC_API}/v1/messages/count_tokens`, {
    method: "POST",
    headers: {
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
      ...credentialHeaders,
    },
    body: JSON.stringify({ model: PROBE_MODEL, messages: [{ role: "user", content: "ping" }] }),
    cache: "no-store",
    signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
  });
  if (response.status === 401 || response.status === 403) {
    return { ok: false, reason: "rejected", status: response.status, message: await errorMessage(response) };
  }
  return { ok: true, email: oauthToken ? await oauthProfileEmail(dependencies, oauthToken) : null };
}

/** Best effort: the token owner's email, or null. Never fails the probe. */
async function oauthProfileEmail(dependencies: CredentialProbeDependencies, token: string): Promise<string | null> {
  try {
    const response = await dependencies.fetch(`${ANTHROPIC_API}/api/oauth/profile`, {
      headers: { authorization: `Bearer ${token}`, "anthropic-beta": OAUTH_BETA, accept: "application/json" },
      cache: "no-store",
      signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
    });
    if (!response.ok) return null;
    const value: unknown = await response.json();
    const account = isRecord(value) && isRecord(value.account) ? value.account : null;
    const email = account && typeof account.email === "string" ? account.email.trim() : "";
    return email && email.length <= 254 ? email : null;
  } catch {
    return null;
  }
}

async function bedrockProbe(
  dependencies: CredentialProbeDependencies,
  input: Extract<ClaudeUpstreamInput, { kind: "bedrock" }>,
): Promise<CredentialProbeResult> {
  const modelId = input.modelIds?.[PROBE_MODEL] ?? BEDROCK_PROBE_MODEL;
  const url = bedrockRuntimeUrl(input.region, modelId, "count-tokens");
  const invoke = JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    max_tokens: 1,
    messages: [{ role: "user", content: "ping" }],
  });
  const body = Buffer.from(JSON.stringify({
    input: { invokeModel: { body: Buffer.from(invoke, "utf8").toString("base64") } },
  }), "utf8");
  const headers = signAwsRequest({
    method: "POST",
    url,
    headers: new Headers({ "content-type": "application/json", accept: "application/json" }),
    body,
    service: "bedrock",
    region: input.region,
    credentials: {
      accessKeyId: input.accessKeyId,
      secretAccessKey: input.secretAccessKey,
      ...(input.sessionToken ? { sessionToken: input.sessionToken } : {}),
    },
    now: dependencies.now(),
  });
  headers.delete("host");
  const response = await dependencies.fetch(url, {
    method: "POST",
    headers,
    body,
    cache: "no-store",
    signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
  });
  if (response.status === 401 || response.status === 403) {
    return { ok: false, reason: "rejected", status: response.status, message: await errorMessage(response) };
  }
  return { ok: true, email: null };
}

async function errorMessage(response: Response): Promise<string> {
  try {
    const text = (await response.text()).slice(0, 2_000);
    const value: unknown = JSON.parse(text);
    if (isRecord(value)) {
      const error = value.error;
      if (isRecord(error) && typeof error.message === "string") return error.message;
      if (typeof value.message === "string") return value.message;
      if (typeof value.Message === "string") return value.Message;
    }
    return text || `HTTP ${response.status}`;
  } catch {
    return `HTTP ${response.status}`;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
