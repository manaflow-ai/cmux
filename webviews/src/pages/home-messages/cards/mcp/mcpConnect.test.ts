// Port of Swift `McpConnectCardFlowTests`: only the person's steps approve, the scope is theirs,
// and a key never prints. Plus the host ops each step sends (mcpHost.ts).
import { inspect } from "node:util";
import { describe, expect, test } from "bun:test";
import {
  isRisky,
  McpConnectFlow,
  McpConnectKey,
  type McpAuth,
  type McpConnectCardData,
  type McpScope,
} from "./mcpConnect";
import { MCP_OPS, sendMcpEffects } from "./mcpHost";

function card(auth: McpAuth, scope: McpScope = "chief"): McpConnectCardData {
  return {
    requestID: "r1",
    agent: "Chief",
    reason: "file issues",
    title: "Linear",
    publisher: "linear.app",
    verified: true,
    transport: { kind: "remote", url: "https://mcp.linear.app/mcp" },
    auth,
    proposedScope: scope,
  };
}

describe("McpConnectFlow", () => {
  test("OAuth connect approves with the chosen scope, then signs in", () => {
    let flow = McpConnectFlow.start(card({ kind: "oauth", scopes: ["read", "write"] }));
    expect(flow.scope).toBe("chief");
    flow = flow.choose("chat");
    const [signing, effects] = flow.connect();
    expect(effects).toEqual([{ kind: "approve", scope: "chat" }, { kind: "beginSignIn" }]);
    expect(signing.phase).toEqual({ kind: "signingIn" });
    const connecting = signing.signedIn();
    expect(connecting.phase).toEqual({ kind: "connecting" });
    const tools = [{ name: "list_issues", kind: "read" as const }];
    expect(connecting.connected(tools).phase).toEqual({ kind: "connected", tools });
  });

  test("the scope cannot change after approval", () => {
    const [flow] = McpConnectFlow.start(card({ kind: "oauth", scopes: [] })).connect();
    expect(flow.choose("everywhere").scope).toBe("chief");
  });

  test("Connect twice sends one approval", () => {
    const [once, first] = McpConnectFlow.start(card({ kind: "none" })).connect();
    expect(first).toEqual([{ kind: "approve", scope: "chief" }]);
    const [twice, second] = once.connect();
    expect(second).toEqual([]);
    expect(twice.phase).toEqual({ kind: "connecting" });
  });

  test("a key server asks for the key and sends it once", () => {
    const [entering, approve] = McpConnectFlow.start(
      card({ kind: "key", name: "CONTEXT7_API_KEY", optional: false }),
    ).connect();
    expect(approve).toEqual([{ kind: "approve", scope: "chief" }]);
    expect(entering.phase).toEqual({ kind: "enterKey" });
    const [blank, none] = entering.submit(new McpConnectKey("  "));
    expect(none).toEqual([]);
    expect(blank.phase).toEqual({ kind: "enterKey" });
    const key = new McpConnectKey("ctx7sk-secret");
    const [connecting, sent] = blank.submit(key);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.kind).toBe("submitKey");
    expect(sent[0]!.kind === "submitKey" && sent[0]!.key.equals(key)).toBe(true);
    expect(connecting.phase).toEqual({ kind: "connecting" });
    expect(connecting.submit(key)[1]).toEqual([]);
  });

  test("an optional key connects without a key", () => {
    const [entering] = McpConnectFlow.start(card({ kind: "key", name: "K", optional: true })).connect();
    const [connecting, effects] = entering.submit(new McpConnectKey(""));
    expect(effects).toEqual([]);
    expect(connecting.phase).toEqual({ kind: "connecting" });
  });

  test("Cancel declines at any step before connected", () => {
    for (let steps = 0; steps <= 2; steps++) {
      let flow = McpConnectFlow.start(card({ kind: "oauth", scopes: [] }));
      if (steps >= 1) flow = flow.connect()[0];
      if (steps >= 2) flow = flow.signedIn();
      const [declined, effects] = flow.cancel();
      expect(effects).toEqual([{ kind: "decline" }]);
      expect(declined.phase).toEqual({ kind: "declined" });
      // A late daemon answer does not revive a declined card.
      expect(declined.connected([]).phase).toEqual({ kind: "declined" });
    }
    const done = McpConnectFlow.start(card({ kind: "none" }))
      .connect()[0]
      .connected([]);
    expect(done.cancel()[1]).toEqual([]);
  });

  test("daemon answers cannot skip the person", () => {
    const flow = McpConnectFlow.start(card({ kind: "oauth", scopes: [] }))
      .signedIn()
      .connected([{ name: "x", kind: "write" }]);
    // Nothing connects before the person pressed Connect.
    expect(flow.phase).toEqual({ kind: "ask" });
  });

  test("a failure shows and ends the card", () => {
    const failed = McpConnectFlow.start(card({ kind: "oauth", scopes: [] }))
      .connect()[0]
      .failed("refused");
    expect(failed.phase).toEqual({ kind: "failed", reason: "refused" });
    expect(failed.cancel()[1]).toEqual([]);
  });

  test("a key never prints", () => {
    const key = new McpConnectKey("ctx7sk-very-secret");
    expect(String(key)).not.toContain("secret");
    expect(JSON.stringify(key)).not.toContain("secret");
    expect(JSON.stringify({ kind: "submitKey", key })).not.toContain("secret");
    expect(inspect(key)).not.toContain("secret");
    expect(inspect({ kind: "submitKey", key }, { showHidden: false })).not.toContain("secret");
    expect(Object.keys(key)).toEqual([]);
    expect(key.reveal()).toBe("ctx7sk-very-secret");
  });

  test("risky means unverified, an international name or local", () => {
    expect(isRisky(card({ kind: "none" }))).toBe(false);
    expect(isRisky({ ...card({ kind: "none" }), verified: false })).toBe(true);
    expect(isRisky({ ...card({ kind: "none" }), idn: true })).toBe(true);
    expect(
      isRisky({
        ...card({ kind: "none" }),
        transport: { kind: "local", argv: ["x"], binarySHA256: "00", fetchesCode: false },
      }),
    ).toBe(true);
  });
});

describe("MCP host ops", () => {
  test("each effect is one op, the key revealed only in submitKey", async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const call = async (op: string, params: Record<string, unknown>) => {
      calls.push([op, params]);
    };
    const key = new McpConnectKey("k-1");
    await sendMcpEffects(call, "r1", [
      { kind: "approve", scope: "chat" },
      { kind: "beginSignIn" },
      { kind: "submitKey", key },
      { kind: "decline" },
    ]);
    expect(calls).toEqual([
      [MCP_OPS.answer, { requestID: "r1", approve: true, scope: "chat" }],
      [MCP_OPS.beginSignIn, { requestID: "r1" }],
      [MCP_OPS.submitKey, { requestID: "r1", key: "k-1" }],
      [MCP_OPS.answer, { requestID: "r1", approve: false }],
    ]);
  });
});
