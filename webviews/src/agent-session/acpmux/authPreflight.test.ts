import { describe, expect, test } from "bun:test";
import { authBlockReason, authPreflight, authState, type HarnessAuth } from "./authPreflight";

const auth: Record<string, HarnessAuth> = {
  claude: { state: "signedOut", login: "claude login" },
  codex: { state: "expired", login: "codex login" },
  sr2: { state: "needsLogin", source: "account", login: "sr2 login" },
};

describe("composer auth preflight", () => {
  test("blocks signed-out and expired local harnesses with their login source", () => {
    expect(authPreflight({ harness: "claude", auth })).toMatchObject({
      state: "signedOut",
      source: "harness",
      login: "claude login",
    });
    expect(authPreflight({ harness: "codex", auth })).toMatchObject({
      state: "expired",
      source: "harness",
      login: "codex login",
    });
    expect(authBlockReason(authPreflight({ harness: "codex", auth }))?.text).toContain("expired");
  });

  test("distinguishes a remote login requirement from an unreachable peer", () => {
    expect(
      authPreflight({
        origin: "peer",
        summary: { harness: "claude", peer: "big-red", authState: "needsLogin" },
        peerStates: { "big-red": "connected" },
        auth,
      }),
    ).toMatchObject({ state: "needsLogin", source: "harness" });

    expect(
      authPreflight({
        origin: "peer",
        summary: { harness: "claude", peer: "big-red", authState: "signedIn" },
        peerStates: { "big-red": "offline" },
        peerConnected: { "big-red": false },
        auth,
      }),
    ).toMatchObject({ state: "unreachable", source: "peer", peer: "big-red" });
  });

  test("keeps the selected harness while a route account needs login", () => {
    expect(
      authPreflight({
        harness: "claude",
        summary: { harness: "claude", authState: "signedIn" },
        auth: { claude: { state: "signedIn" }, sr2: auth.sr2 },
      }),
    ).toEqual({ state: "ready" });
    expect(authState("missing")).toBe("missing");
  });

  test("maps a credential-store loss to the migration source", () => {
    const result = authPreflight({
      harness: "claude",
      summary: { harness: "claude", authState: "missing" },
    });
    expect(result).toEqual({ state: "missing", source: "migration" });
    expect(authBlockReason(result)?.text).toContain("migration");
  });

  test("does not invent a failure when status is absent", () => {
    expect(authPreflight({ harness: "claude" })).toEqual({ state: "ready" });
  });
});
