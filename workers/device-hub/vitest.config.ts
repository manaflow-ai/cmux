import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

async function testKey(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d });
}

export const TEST_STACK_PROJECT = "test-project";
export const TEST_STACK_DEV_PROJECT = "test-dev-project";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          SESSION_KEY: await testKey(),
          TICKET_KEY: await testKey(),
          STACK_PROJECT_IDS: `${TEST_STACK_PROJECT},${TEST_STACK_DEV_PROJECT}`,
          STACK_API_URL: "https://stack.test",
          // Hub user ids are "<projectId>:<sub>".
          PAID_USER_IDS: `${TEST_STACK_PROJECT}:paid-user`,
          TURN_KEY_ID: "turn-key",
          TURN_KEY_API_TOKEN: "turn-token",
          // Short provisional window for socket-close end reasons (default 3 s).
          CLOSE_GRACE_MS: "300",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
