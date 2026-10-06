import { describe, expect, test } from "bun:test";
import { type ChildResult, runChild } from "./helpers/run-child";

const requiredEnv = {
  PATH: process.env.PATH ?? "",
  HOME: process.env.HOME ?? "",
  RESEND_API_KEY: "test-resend",
  CMUX_FEEDBACK_FROM_EMAIL: "hello@example.com",
  CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback-rule",
  STACK_SECRET_SERVER_KEY: "stack-secret",
  NEXT_PUBLIC_STACK_PROJECT_ID: "stack-project",
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "stack-public",
};

const requiredIrohProductionEnv = {
  CMUX_IROH_LAN_DISCOVERY_SECRET_B64: Buffer.alloc(32, 0x11).toString("base64"),
  CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64: Buffer.alloc(32, 0x22).toString("base64"),
  CMUX_IROH_GRANT_SIGNING_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${"A".repeat(64)}\n-----END PRIVATE KEY-----`,
  CMUX_IROH_GRANT_SIGNING_KID: "current",
  CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON: "{}",
  CMUX_IROH_MINT_URL: "https://iroh-minter.example.com/api/relay-token",
  CMUX_IROH_MINT_HMAC_SECRET_B64: Buffer.alloc(32, 0x33).toString("base64"),
};

const requiredRelayProductionEnv = {
  CMUX_RELAY_JWT_PRIVATE_KEY_PEM:
    `-----BEGIN PRIVATE KEY-----\n${"B".repeat(64)}\n-----END PRIVATE KEY-----`,
  CMUX_RELAY_POLICY_KEY_ID: "relay-policy-current",
  CMUX_RELAY_POLICY_PRIVATE_KEY_PEM:
    `-----BEGIN PRIVATE KEY-----\n${"C".repeat(64)}\n-----END PRIVATE KEY-----`,
  CMUX_RELAY_TOKEN_RATE_LIMIT_ID: "relay-token-rule",
};

// Origin returned with CodeRouter handoff route tokens; deployed
// non-preview runtimes require it (app/env.ts).
const requiredCoderouterProductionEnv = {
  CMUX_CODEROUTER_PUBLIC_ORIGIN: "https://cmux.example.com",
};

const requiredSubrouterDeploymentEnv = {
  SUBROUTER_ADMIN_TOKEN: "test-legacy-subrouter-admin",
  SUBROUTER_STACK_TENANT_DELETE_TOKEN: "0123456789abcdef0123456789abcdef",
};

describe("client config env validation", () => {
  test("allows local builds with VERCEL set but no deployment environment", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_PREVIEW_COMMENTS_ENABLED: "0",
    });

    expect(result.status).toBe(0);
    expect(result.stderr).not.toContain("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID is required");
  });

  test("production needs no subrouter or coderouter access-gate variables", async () => {
    // Access is team membership only. A deploy that still carries the retired
    // gate keys must also start, since the runtime ignores them.
    const without = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
    });
    expect(without.status).toBe(0);
    expect(without.stderr).not.toContain("CODEROUTER_HOSTED_PRO_REQUIRED");
    expect(without.stderr).not.toContain("SUBROUTER_ENFORCE_STACK_PERMISSIONS");
    expect(without.stderr).not.toContain("SUBROUTER_ALLOWED_TEAM_IDS");

    const withStale = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
      CODEROUTER_HOSTED_PRO_REQUIRED: "1",
      SUBROUTER_ENFORCE_STACK_PERMISSIONS: "1",
      SUBROUTER_ALLOWED_TEAM_IDS: "team-a",
    });
    expect(withStale.status).toBe(0);
  });

  test("rejects every retired Stripe price override at startup", async () => {
    // A retired override would pin checkout to a grandfathered Price, so the
    // deployment must fail loudly rather than sell at the old amount.
    const retired = [
      ["STRIPE_PRO_MONTHLY_PRICE_ID", "STRIPE_PRO_MONTHLY_50_PRICE_ID"],
      ["STRIPE_PRO_YEARLY_PRICE_ID", "STRIPE_PRO_YEARLY_480_PRICE_ID"],
      ["STRIPE_PRO_YEARLY_288_PRICE_ID", "STRIPE_PRO_YEARLY_480_PRICE_ID"],
      ["STRIPE_TEAM_MONTHLY_PRICE_ID", "STRIPE_TEAM_MONTHLY_60_PRICE_ID"],
      ["STRIPE_TEAM_YEARLY_PRICE_ID", "STRIPE_TEAM_YEARLY_576_PRICE_ID"],
    ] as const;
    for (const [name, replacement] of retired) {
      const result = await importEnv({
        ...requiredEnv,
        [name]: "price_grandfathered",
      });

      expectRejected(result);
      expect(result.stderr).toContain(`${name} is retired; use ${replacement}`);
    }
  });

  test("accepts the current Stripe price overrides", async () => {
    const result = await importEnv({
      ...requiredEnv,
      STRIPE_PRO_MONTHLY_50_PRICE_ID: "price_pro_50",
      STRIPE_PRO_YEARLY_550_PRICE_ID: "price_pro_550",
      STRIPE_TEAM_MONTHLY_60_PRICE_ID: "price_team_60",
      STRIPE_TEAM_YEARLY_660_PRICE_ID: "price_team_660",
    });

    expect(result.status).toBe(0);
  });

  test("allows explicit Vercel production deployments with all rate-limit ids unset", async () => {
    // Rate limiting is opt-in: production deploys must survive every
    // rate-limit id being deleted from the environment.
    const { CMUX_RELAY_TOKEN_RATE_LIMIT_ID: _relay, ...relayEnv } = requiredRelayProductionEnv;
    const { CMUX_FEEDBACK_RATE_LIMIT_ID: _feedback, ...baseEnv } = requiredEnv;
    const result = await importEnv({
      ...baseEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...relayEnv,
      ...requiredCoderouterProductionEnv,
    });

    expect(result.status).toBe(0);
    expect(result.stderr).not.toContain("RATE_LIMIT_ID");
  });

  test("production requires the CodeRouter public origin", async () => {
    const base = {
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
    };
    const missing = await importEnv(base);
    expect(missing.status).not.toBe(0);
    expect(missing.stderr).toContain("CMUX_CODEROUTER_PUBLIC_ORIGIN");
    const withPath = await importEnv({ ...base, CMUX_CODEROUTER_PUBLIC_ORIGIN: "https://cmux.example.com/v1" });
    expect(withPath.status).not.toBe(0);
  });

  test("accepts explicit Vercel production deployments with both limiter ids", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
    });

    expect(result.status).toBe(0);
  });

  test("allows hosted-only production after the temporary legacy admin token is retired", async () => {
    const { SUBROUTER_ADMIN_TOKEN: _legacyToken, ...hostedSubrouterEnv } =
      requiredSubrouterDeploymentEnv;
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...hostedSubrouterEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
    });

    expect(result.status).toBe(0);
    expect(result.stderr).not.toContain("SUBROUTER_ADMIN_TOKEN");
  });

  test("allows credential-free docs channel deployments", async () => {
    const result = await importEnv({
      PATH: requiredEnv.PATH,
      HOME: requiredEnv.HOME,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_DOCS_CHANNEL: "nightly",
    });

    expect(result.status).toBe(0);
  });

  test("allows explicit Vercel production deployments without the analytics limiter id", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
    });

    expect(result.status).toBe(0);
    expect(result.stderr).not.toContain("CMUX_ANALYTICS_RATE_LIMIT_ID");
  });

  test("allows Vercel development without the analytics limiter id", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "development",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredSubrouterDeploymentEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
    });

    expect(result.status).toBe(0);
  });
  test("accepts the self-hosted relay path without the legacy hosted minter", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      CMUX_IROH_LAN_DISCOVERY_SECRET_B64: requiredIrohProductionEnv.CMUX_IROH_LAN_DISCOVERY_SECRET_B64,
      CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64: requiredIrohProductionEnv.CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64,
      CMUX_IROH_GRANT_SIGNING_KEY_P8: requiredIrohProductionEnv.CMUX_IROH_GRANT_SIGNING_KEY_P8,
      CMUX_IROH_GRANT_SIGNING_KID: requiredIrohProductionEnv.CMUX_IROH_GRANT_SIGNING_KID,
      CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON:
        requiredIrohProductionEnv.CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON,
      ...requiredSubrouterDeploymentEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
    });

    expect(result.status).toBe(0);
  });

  test("allows explicit Vercel production without the optional Iroh limiter id", async () => {
    const result = await importEnv({
      ...requiredEnv,
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredSubrouterDeploymentEnv,
    });

    expect(result.status).toBe(0);
    expect(result.stderr).not.toContain("CMUX_IROH_RATE_LIMIT_ID is required");
  });

  test("requires the complete Iroh trust-broker configuration in production", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      CMUX_IROH_RATE_LIMIT_ID: "iroh-rule",
      ...requiredSubrouterDeploymentEnv,
    });

    expectRejected(result);
    expect(result.stderr).toContain("CMUX_IROH_GRANT_SIGNING_KEY_P8 is required");
    expect(result.stderr).not.toContain("CMUX_IROH_MINT_HMAC_SECRET_B64 is required");
  });

  test("requires the self-hosted relay signing and rate-limit configuration in production", async () => {
    const result = await importEnv({
      ...requiredEnv,
      ...requiredIrohProductionEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredSubrouterDeploymentEnv,
    });

    expectRejected(result);
    expect(result.stderr).toContain("Self-hosted relay runtime configuration is incomplete");
    expect(result.stderr).not.toContain("CMUX_RELAY_JWT_PRIVATE_KEY_PEM");
    expect(result.stderr).not.toContain("CMUX_RELAY_POLICY_KEY_ID");
    expect(result.stderr).not.toContain("CMUX_RELAY_POLICY_PRIVATE_KEY_PEM");
    expect(result.stderr).not.toContain("CMUX_RELAY_TOKEN_RATE_LIMIT_ID");
  });

  test("keeps Vercel previews credential-free for the self-hosted relay fleet", async () => {
    const result = await importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "preview",
    });

    expect(result.status).toBe(0);
  });

  test("allows an explicitly opted-in loopback HTTP relay minter only in local development", async () => {
    const result = await inspectIrohMinterUrl({
      ...requiredEnv,
      NODE_ENV: "development",
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://localhost:49152/api/relay-token",
    });

    expect(result.status).toBe(0);
    expect(result.stdout).toBe("http://localhost:49152/api/relay-token");
  });

  test("rejects a plaintext non-loopback relay minter in local development", async () => {
    const result = await inspectIrohMinterUrl({
      ...requiredEnv,
      NODE_ENV: "development",
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://192.168.1.10:49152/api/relay-token",
    });

    expectRejected(
      result,
      "CMUX_IROH_MINT_URL must use HTTPS, except for an opted-in local loopback development minter",
    );
  });

  test("rejects the insecure loopback opt-in in Vercel preview and production", async () => {
    const preview = await inspectIrohMinterUrl({
      ...requiredEnv,
      NODE_ENV: "production",
      VERCEL: "1",
      VERCEL_ENV: "preview",
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://localhost:49152/api/relay-token",
    });
    expectRejected(preview, 'component: "relay_minter"');

    const production = await inspectIrohMinterUrl({
      ...requiredEnv,
      ...requiredIrohProductionEnv,
      NODE_ENV: "production",
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredSubrouterDeploymentEnv,
      ...requiredRelayProductionEnv,
      ...requiredCoderouterProductionEnv,
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://localhost:49152/api/relay-token",
    });
    expectRejected(production);
    expect(production.stderr).toContain(
      "CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER is only allowed in local development",
    );
  });
});

// A rejection must be the validation failure itself: a clean nonzero exit with
// the expected diagnostic. A child killed by the spawn timeout or a signal also
// exits nonzero, so it must never count as the rejection under test.
function expectRejected(result: ChildResult, ...diagnostics: string[]): void {
  expect(result.signal).toBeNull();
  expect(result.status).not.toBe(0);
  for (const diagnostic of diagnostics) {
    expect(result.stderr).toContain(diagnostic);
  }
}

/** Runs this Bun binary without .env loading, under exactly the given environment. */
function runBun(args: string[], env: Record<string, string>): Promise<ChildResult> {
  return runChild(process.execPath, ["--no-env-file", ...args], { env, timeout: 30_000 });
}

/** Imports app/env in a fresh Bun process so its startup validation runs. */
async function importEnv(env: Record<string, string>): Promise<ChildResult> {
  return runBun(["-e", "await import('./app/env')"], env);
}

/** Resolves the relay minter URL in a fresh Bun process and prints its href. */
async function inspectIrohMinterUrl(
  env: Record<string, string>,
): Promise<ChildResult> {
  const result = await runBun(["-e", `
        const { irohTrustBrokerConfigFromEnv } = await import('./services/iroh/config');
        const { parseMinterUrl } = await import('./services/iroh/relayMinter');
        const config = irohTrustBrokerConfigFromEnv();
        const url = parseMinterUrl(config.relayMinterUrl, {
          allowInsecureLoopback: config.relayMinterInsecureLoopbackOptIn,
          deploymentEnvironment: config.deploymentEnvironment,
          isVercelDeployment: config.isVercelDeployment,
        });
        console.log(url.href);
      `], env);
  return { ...result, stdout: result.stdout.trim() };
}
