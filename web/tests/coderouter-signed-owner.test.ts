import { expect, test } from "bun:test";
import { addAccount } from "../services/coderouter/accounts";

test("rejects unsigned owner claims before any account lookup", async () => {
  const token = `eyJhbGciOiJub25lIn0.${Buffer.from(JSON.stringify({ email: "fake@example.com", "https://api.openai.com/auth": { chatgpt_user_id: "forged-user", chatgpt_account_id: "forged-workspace" } })).toString("base64url")}.signature`;
  await expect(addAccount("team", {
    provider: "codex", accessToken: token, idToken: token, refreshToken: "fake",
    accountId: "forged-workspace", email: "fake@example.com", expiresAt: Date.now()+3600000,
  })).rejects.toThrow("Codex credential signature is invalid");
});
