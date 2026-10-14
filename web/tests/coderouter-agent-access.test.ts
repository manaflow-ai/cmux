import { describe, expect, mock, test } from "bun:test";
import { makeAgentAccessHandler } from "../app/api/coderouter/agent-access/route";
import { RESPONSES_PROVIDERS } from "../services/coderouter/types";

const request = () => new Request("https://cmux.com/api/coderouter/agent-access");
const vmAccess = { kind: "vm", poolId: "pool-1" };

function handler(options: {
  claude?: readonly { state: string }[];
  configured?: readonly string[];
  failing?: boolean;
  unauthorized?: boolean;
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
  });
  return { GET, hasActiveClaude, hasConfigured };
}

describe("coderouter agent access", () => {
  test("answers, per agent, whether the team can serve it, as the proxies decide", async () => {
    const { GET, hasActiveClaude, hasConfigured } = handler({ claude: [{ state: "active" }], configured: ["opencode-go"] });
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ teamId: "team-1", agents: { claude: true, codex: false, opencode: true } });
    // The caller's own access scope decides which accounts count.
    expect(hasActiveClaude).toHaveBeenCalledWith("team-1", vmAccess);
    expect(hasConfigured).toHaveBeenCalledWith({ teamId: "team-1", provider: RESPONSES_PROVIDERS, access: vmAccess });
    expect(hasConfigured).toHaveBeenCalledWith({ teamId: "team-1", provider: "opencode-go", access: vmAccess });
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
