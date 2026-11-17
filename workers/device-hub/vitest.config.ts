import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

async function testKey(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d });
}

export const TEST_STACK_PROJECT = "test-project";
export const TEST_STACK_DEV_PROJECT = "test-dev-project";

// cmux-platform's TurnMinter entrypoint (wrangler.toml's TURN_MINTER binding names
// cmux-platform-production), as the platform answers while it has no TURN key: [].
// Every paid-session test therefore gets the hub's own mint through the fallback;
// test/turn.test.ts covers a platform that answers.
const TURN_MINTER_KEYLESS = `
import { WorkerEntrypoint } from "cloudflare:workers";
export class TurnMinter extends WorkerEntrypoint {
  ice() {
    return [];
  }
}
export default { fetch: () => new Response(null, { status: 404 }) };
`;

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        workers: [{ name: "cmux-platform-production", modules: true, script: TURN_MINTER_KEYLESS, compatibilityDate: "2026-09-01" }],
        bindings: {
          SESSION_KEY: await testKey(),
          TICKET_KEY: await testKey(),
          STACK_PROJECT_IDS: `${TEST_STACK_PROJECT},${TEST_STACK_DEV_PROJECT}`,
          STACK_API_URL: "https://stack.test",
          // cmux web backend per Stack project; the hub asks it for the caller's plan.
          BILLING_ORIGINS: `${TEST_STACK_PROJECT}=https://billing.test,${TEST_STACK_DEV_PROJECT}=https://billing-dev.test`,
          // A short billing deadline so the "billing hangs" test ends quickly (default 5 s).
          BILLING_TIMEOUT_MS: "300",
          // cmux-platform per Stack project; the hub asks it whose a joined machine's credential is.
          MACHINE_ORIGINS: `${TEST_STACK_PROJECT}=https://platform.test`,
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
