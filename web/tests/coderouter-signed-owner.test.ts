import { expect, test } from "bun:test";
import { addAccount } from "../services/coderouter/accounts";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { verifyCodexCredential, verifyStoredCodexCredential } from "../services/coderouter/codexSignature";
import { needsCodexOwnerMigration } from "../services/coderouter/codexIdentity";

test("rejects unsigned owner claims before any account lookup", async () => {
  const token = `eyJhbGciOiJub25lIn0.${Buffer.from(JSON.stringify({ email: "fake@example.com", "https://api.openai.com/auth": { chatgpt_user_id: "forged-user", chatgpt_account_id: "forged-workspace" } })).toString("base64url")}.signature`;
  await expect(addAccount("team", {
    provider: "codex", accessToken: token, idToken: token, refreshToken: "fake",
    accountId: "forged-workspace", email: "fake@example.com", expiresAt: Date.now()+3600000,
  })).rejects.toThrow("Codex credential signature is invalid");
});

test("verifies issuer, audience and signatures for both credentials", async () => {
  const now = new Date("2026-09-13T00:00:00Z");
  const issued = Math.floor(now.getTime() / 1000);
  const pair = await generateKeyPair("RS256", { extractable: true });
  const jwk = await exportJWK(pair.publicKey);
  const keys = createLocalJWKSet({ keys: [{ ...jwk, kid: "fixture-key", alg: "RS256" }] });
  const sign = (audience: string, issuer = "https://auth.openai.com") => new SignJWT({ "https://api.openai.com/auth": { chatgpt_user_id: "user", chatgpt_account_id: "workspace" } })
    .setProtectedHeader({ alg: "RS256", kid: "fixture-key" }).setIssuedAt(issued).setSubject("user").setExpirationTime(issued + 300).setIssuer(issuer).setAudience(audience).sign(pair.privateKey);
  const idToken = await sign("app_EMoamEEZ73f0CkXaXp7hrann");
  const accessToken = await sign("https://api.openai.com/v1");
  const credential = { provider: "codex" as const, idToken, accessToken, accountId: "workspace", email: "fixture@example.com", refreshToken: "synthetic", expiresAt: Date.now()+60_000 };
  await verifyCodexCredential(credential, keys, now);
  await verifyStoredCodexCredential(credential, keys);
  await expect(verifyCodexCredential(credential, keys, new Date(now.getTime()+600_000))).rejects.toThrow();
  await expect(verifyCodexCredential({ ...credential, idToken: await sign("wrong-client") }, keys, now)).rejects.toThrow("signature is invalid");
  await expect(verifyCodexCredential({ ...credential, accessToken: await sign("https://api.openai.com/v1", "https://wrong.example.com") }, keys, now)).rejects.toThrow("signature is invalid");
  const pieces = accessToken.split(".");
  pieces[1] = Buffer.from(JSON.stringify({ sub: "forged" })).toString("base64url");
  await expect(verifyCodexCredential({ ...credential, accessToken: pieces.join(".") }, keys, now)).rejects.toThrow("signature is invalid");
  await expect(verifyStoredCodexCredential({ ...credential, accessToken: pieces.join(".") }, keys)).rejects.toThrow("signature is invalid");
});

test("migration planning rejects an existing owner mismatch", () => {
  const token = `h.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_user_id: "user", chatgpt_account_id: "workspace" } })).toString("base64url")}.s`;
  const credential = { provider: "codex" as const, idToken: token, accessToken: token, accountId: "workspace", email: "fixture@example.com", refreshToken: "synthetic", expiresAt: Date.now()+60_000 };
  expect(needsCodexOwnerMigration({ providerAccountId: "workspace" }, credential)).toBe(true);
  expect(needsCodexOwnerMigration({ providerAccountId: "workspace", providerUserId: "user" }, credential)).toBe(false);
  expect(() => needsCodexOwnerMigration({ providerAccountId: "workspace", providerUserId: "other" }, credential)).toThrow();
});
