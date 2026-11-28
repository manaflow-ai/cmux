import { describe, expect, test } from "bun:test";
import { allSpentDetail, claudeLoginCandidates, classifyLoginProbe, pickClaudeLogin, probeClaudeLogin, resetWords } from "./claude-login-pool";
import { FIXTURE_LOGIN, runJourney } from "./cloud-journey-fake";

const A = `sk-ant-oat01-${"b".repeat(40)}`;
const B = `sk-ant-oat01-${"c".repeat(40)}`;
// cmuxterm-hq tools/fleet-reconcilers/cloud_chat_app_probe.py AGENT_TURN_LIMIT_RE: the words cap.agent_quota skips on.
const AGENT_TURN_LIMIT_RE = /You've hit your ((?:5-hour |weekly |weekly Opus |weekly Sonnet |usage )?limit)(?: · resets ([^()·]{1,40}?) \(UTC\))?/;

describe("the Claude login pool", () => {
  test("candidates are the pool lines, then the journey login, then the repository's, each once", () => {
    const env = { CMUX_JOURNEY_CLAUDE_OAUTH_POOL: ` ${A}\n\n# a comment\r\n${B}\n${A}\n`, CLAUDE_CODE_OAUTH_TOKEN: B, CLAUDE_CODE_OAUTH_TOKEN_FALLBACK: FIXTURE_LOGIN };
    expect(claudeLoginCandidates(env)).toEqual([A, B, FIXTURE_LOGIN]);
    expect(claudeLoginCandidates({ CLAUDE_CODE_OAUTH_TOKEN: "" }, { CLAUDE_CODE_OAUTH_TOKEN: A })).toEqual([A]);
    expect(claudeLoginCandidates({})).toEqual([]);
  });

  test("a 429 or a rejected window is spent, 401/403 refused, anything else unknown", () => {
    const reset = Date.UTC(2026, 10, 18, 3) / 1000;
    expect(classifyLoginProbe(200, {}).status).toBe("ok");
    expect(classifyLoginProbe(200, { "anthropic-ratelimit-unified-status": "rejected" }).status).toBe("spent");
    const spent = classifyLoginProbe(429, { "Anthropic-Ratelimit-Unified-Status": "rejected", "anthropic-ratelimit-unified-reset": String(reset) });
    expect(spent).toEqual({ status: "spent", reason: "HTTP 429 unified=rejected resets 2026-11-18T03:00:00Z", resetAt: "2026-11-18T03:00:00Z" });
    expect(classifyLoginProbe(401, {}, { error: { type: "authentication_error" } })).toEqual({ status: "invalid", reason: "HTTP 401 authentication_error", resetAt: null });
    expect(classifyLoginProbe(403, {}).status).toBe("invalid");
    for (const status of [400, 404, 500, 529]) expect(classifyLoginProbe(status, {}).status).toBe("unknown");
  });

  test("the preflight is one max_tokens 1 request with the OAuth beta header, and a thrown fetch is unknown", async () => {
    const seen: { url: string; init: RequestInit }[] = [];
    const ok = await probeClaudeLogin(A, (async (url: string, init: RequestInit) => {
      seen.push({ url, init });
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch);
    expect(ok.status).toBe("ok");
    expect(seen).toHaveLength(1);
    const headers = seen[0].init.headers as Record<string, string>;
    expect(headers.authorization).toBe(`Bearer ${A}`);
    expect(headers["anthropic-beta"]).toBe("oauth-2025-04-20");
    expect(JSON.parse(String(seen[0].init.body)).max_tokens).toBe(1);
    const down = await probeClaudeLogin(A, (async () => { throw new TypeError("fetch failed"); }) as unknown as typeof fetch);
    expect(down.status).toBe("unknown");
    expect(down.reason).not.toContain(A);
  });

  test("the pick takes the first ok slot, else the first unknown one, else none", async () => {
    const answers = (map: Record<string, "ok" | "spent" | "invalid" | "unknown">) => async (t: string) => ({ status: map[t], reason: map[t], resetAt: map[t] === "spent" ? "2026-11-30T07:00:00Z" : null });
    const second = await pickClaudeLogin([A, B, FIXTURE_LOGIN], answers({ [A]: "spent", [B]: "ok", [FIXTURE_LOGIN]: "ok" }));
    expect(second.slot).toBe(1);
    expect(second.login).toBe(B);
    expect(second.rotation.map((r) => r.status)).toEqual(["spent", "ok"]);
    const failOpen = await pickClaudeLogin([A, B], answers({ [A]: "unknown", [B]: "spent" }));
    expect(failOpen.slot).toBe(0);
    const none = await pickClaudeLogin([A, B], answers({ [A]: "spent", [B]: "invalid" }));
    expect(none.login).toBeNull();
    expect(none.resetAt).toBe("2026-11-30T07:00:00Z");
    const detail = allSpentDetail(none);
    expect(detail).toContain("infra: claude login spent (all 2 slots; 1 refused)");
    expect(detail.match(AGENT_TURN_LIMIT_RE)?.[2]).toBe("Nov 30, 7am");
    expect(resetWords("2026-11-18T15:30:00Z")).toBe("Nov 18, 3:30pm");
  });
});

describe("the journey rotates its Claude login before the machine is made", () => {
  test("a spent first slot moves the run to the next; probe.json names the slot, never a token", () => {
    const { steps, probe, log, stdout } = runJourney({ login: FIXTURE_LOGIN, pool: `${A}\n${B}`, loginAnswers: { [A]: { status: 429, reset: 1_800_000_000 } } });
    expect(log.filter((l) => l.startsWith("login preflight") && l.includes("max_tokens=1 "))).toEqual(["login preflight 429 max_tokens=1 beta=oauth-2025-04-20", "login preflight 200 max_tokens=1 beta=oauth-2025-04-20"]);
    expect(log.indexOf("login preflight 200 max_tokens=1 beta=oauth-2025-04-20")).toBeLessThan(log.indexOf("create"));
    expect(probe.login_slot).toBe(1);
    expect(probe.login_rotation.map((r: any) => r.status)).toEqual(["spent", "ok"]);
    expect(steps.find((s) => s.step === "login rotation")?.detail).toContain("slot 1 of 3");
    const written = JSON.stringify({ probe, steps });
    for (const token of [A, B, FIXTURE_LOGIN]) expect(written).not.toContain(token);
    expect(stdout).not.toContain(A);
  });

  test("every slot spent: an infra row in the limit words, and no machine is created", () => {
    const reset = Date.UTC(2026, 10, 30, 7) / 1000;
    const { steps, probe, log } = runJourney({ login: FIXTURE_LOGIN, pool: A, loginAnswers: { [A]: { status: 429, reset }, [FIXTURE_LOGIN]: { status: 429, reset } } });
    expect(log).not.toContain("create");
    expect(probe.outcome).toBe("fail");
    expect(probe.login_slot).toBeNull();
    expect(probe.error).toContain("infra: claude login spent (all 2 slots)");
    expect(String(probe.error).match(AGENT_TURN_LIMIT_RE)?.[2]).toBe("Nov 30, 7am");
    expect(steps.find((s) => s.step === "pass Claude login")?.status).toBe("fail");
  });

  test("one login and no pool: one preflight, slot 0, the run as before", () => {
    const { probe, log } = runJourney({ login: FIXTURE_LOGIN });
    expect(log.filter((l) => l.startsWith("login preflight") && l.includes("max_tokens=1 "))).toHaveLength(1);
    expect(probe.login_slot).toBe(0);
    expect(log).toContain("create");
  });
});
