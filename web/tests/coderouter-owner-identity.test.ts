import { describe, expect, test } from "bun:test";
import { parseCredential } from "../services/coderouter/accounts";
import { refreshProviderCredential } from "../services/coderouter/refresh";

function token(user: string, workspace: string, email = "shared@example.com") {
  return `header.${Buffer.from(JSON.stringify({ email, "https://api.openai.com/auth": { chatgpt_user_id: user, chatgpt_account_id: workspace } })).toString("base64url")}.signature`;
}

function credential(user = "user-1", workspace = "team") {
  return { provider: "codex" as const, accessToken: token(user, workspace), idToken: token(user, workspace), refreshToken: "synthetic-refresh", accountId: workspace, email: "shared@example.com", expiresAt: Date.now() + 3_600_000 };
}

describe("Codex credential owner", () => {
  test("extracts the immutable user as well as the selected workspace", () => {
    expect(parseCredential(credential())).toMatchObject({ userId: "user-1", accountId: "team" });
  });
  test("rejects conflicting claimed user IDs", () => {
    expect(parseCredential({ ...credential(), userId: "user-2" })).toBeNull();
  });
  test("rejects refreshed tokens from a different user in the same workspace", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = (async () => Response.json({ access_token: token("user-2", "team"), id_token: token("user-2", "team"), refresh_token: "rotated" })) as typeof fetch;
    try { await expect(refreshProviderCredential(credential())).rejects.toThrow(); }
    finally { globalThis.fetch = original; }
  });
});
