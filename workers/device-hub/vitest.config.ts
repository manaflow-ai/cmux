import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

async function testKey(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d });
}

/** A PKCS#8 PEM P-256 key, as an APNs auth key (.p8) looks. */
async function testP8(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der));
  return `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----`;
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
          // cmux web backend per Stack project; the hub asks it for the caller's plan.
          BILLING_ORIGINS: `${TEST_STACK_PROJECT}=https://billing.test,${TEST_STACK_DEV_PROJECT}=https://billing-dev.test`,
          // A short billing deadline so the "billing hangs" test ends quickly (default 5 s).
          BILLING_TIMEOUT_MS: "300",
          TURN_KEY_ID: "turn-key",
          TURN_KEY_API_TOKEN: "turn-token",
          // Short provisional window for socket-close end reasons (default 3 s).
          CLOSE_GRACE_MS: "300",
          // Computer Use approval pushes go to a mocked APNs (test/helpers.ts).
          APNS_KEY_P8: await testP8(),
          APNS_KEY_ID: "APNSKEY001",
          APNS_TEAM_ID: "TEAM000001",
          APNS_TOPICS: "dev.cmux.mobile.prod,dev.cmux.mobile",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
