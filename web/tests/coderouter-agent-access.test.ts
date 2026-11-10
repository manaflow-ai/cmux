import { describe, expect, mock, test } from "bun:test";
import { gatewayFallbackEnabled, makeAgentAccessHandler } from "../app/api/coderouter/agent-access/route";
import { RESPONSES_PROVIDERS } from "../services/coderouter/types";

const request = () => new Request("https://cmux.com/api/coderouter/agent-access");
const vmAccess = { kind: "vm", poolId: "pool-1" };

function handler(options: {
  claude?: readonly { state: string }[];
  configured?: readonly string[];
  failing?: boolean;
  unauthorized?: boolean;
  fallback?: string;
} = {}) {
  const resolveUsageTeam = mock(async () => options.unauthorized
    ? { ok: false as const, response: Response.json({ error: "invalid_token" }, { status: 401 }) }
    : { ok: true as const, teamId: "team-1", stackUserId: "user-1", access: vmAccess });
  const hasActiveClaude = mock(async () => {
    if (options.failing) throw new Error("db down");
    return (options.claude ?? []).some((account) => account.state === "active");
  });
  const hasConfigured = mock(async (input: { provider: unknown }) => {
    const providers = typeof input.provider === "string" ? [input.provider] : input.provider as readonly string[];
    return providers.some((provider) => (options.configured ?? []).includes(provider));
  });
  const GET = makeAgentAccessHandler({
    resolveUsageTeam: resolveUsageTeam as never,
    hasActiveClaude: hasActiveClaude as never,
    hasConfigured: hasConfigured as never,
    gatewayFallbackEnv: () => options.fallback,
  });
  return { GET, hasActiveClaude, hasConfigured };
}

describe("coderouter agent access", () => {
  test("answers, per agent, whether the team can serve it, as the proxies decide", async () => {
    const { GET, hasActiveClaude, hasConfigured } = handler({ claude: [{ state: "active" }], configured: ["opencode-go"] });
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      teamId: "team-1",
      agents: { claude: true, codex: false, opencode: true },
      gatewayFallback: false,
    });
    // The caller's own access scope decides which accounts count.
    expect(hasActiveClaude).toHaveBeenCalledWith("team-1", vmAccess);
    expect(hasConfigured).toHaveBeenCalledWith({ teamId: "team-1", provider: RESPONSES_PROVIDERS, access: vmAccess });
    expect(hasConfigured).toHaveBeenCalledWith({ teamId: "team-1", provider: "opencode-go", access: vmAccess });
  });

  test("the gateway fallback is off by default and on only when the deployment says so", async () => {
    // Leo, 2026-11-10: off "until the founders turn billing on".
    for (const raw of [undefined, "", "0", "false", "off", "nope"]) expect(gatewayFallbackEnabled(raw)).toBe(false);
    for (const raw of ["1", "true", "YES", " on "]) expect(gatewayFallbackEnabled(raw)).toBe(true);
    expect((await (await handler().GET(request())).json()).gatewayFallback).toBe(false);
    expect((await (await handler({ fallback: "1" }).GET(request())).json()).gatewayFallback).toBe(true);
    // The deployment's own default (no dependency override) reads CMUX_GATEWAY_FALLBACK, unset in tests.
    const saved = process.env.CMUX_GATEWAY_FALLBACK;
    delete process.env.CMUX_GATEWAY_FALLBACK;
    try {
      const { hasConfigured, hasActiveClaude } = handler();
      const GET = makeAgentAccessHandler({
        resolveUsageTeam: (async () => ({ ok: true, teamId: "team-1", stackUserId: "u", access: vmAccess })) as never,
        hasActiveClaude: hasActiveClaude as never,
        hasConfigured: hasConfigured as never,
      });
      expect((await (await GET(request())).json()).gatewayFallback).toBe(false);
    } finally {
      if (saved !== undefined) process.env.CMUX_GATEWAY_FALLBACK = saved;
    }
  });

  test("a team whose Claude accounts are all disabled cannot serve Claude Code", async () => {
    const { GET } = handler({ claude: [{ state: "disabled" }], configured: [...RESPONSES_PROVIDERS] });
    expect((await (await GET(request())).json()).agents).toEqual({ claude: false, codex: true, opencode: false });
  });

  test("an unauthenticated caller gets the resolver's refusal, and a failed lookup a retryable 503", async () => {
    expect((await handler({ unauthorized: true }).GET(request())).status).toBe(401);
    const failed = await handler({ failing: true }).GET(request());
    expect(failed.status).toBe(503);
    expect(failed.headers.get("retry-after")).toBe("5");
    expect((await failed.json()).retryable).toBe(true);
  });
});
