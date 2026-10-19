import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

async function testKey(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d });
}

export const TEST_STACK_PROJECT = "test-project";
export const PAID_USER = "paid-user";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          SESSION_KEY: await testKey(),
          TICKET_KEY: await testKey(),
          STACK_PROJECT_ID: TEST_STACK_PROJECT,
          STACK_API_URL: "https://stack.test",
          PAID_USER_IDS: PAID_USER,
          TURN_KEY_ID: "turn-key",
          TURN_KEY_API_TOKEN: "turn-token",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
