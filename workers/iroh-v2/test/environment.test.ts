import { expect, test } from "bun:test";
import { runtime, type Environment } from "../src/environment";

function environment(overrides: Record<string, unknown>): Environment {
  return {
    ENVIRONMENT: "development", STACK_PROJECT_ID: "project",
    STACK_API_URL: "https://api.stack-auth.com", STACK_PUBLISHABLE_KEY: "public",
    API_TICKET_KEYS: JSON.stringify({ current: "a".repeat(43) }),
    API_TICKET_CURRENT_KEY_ID: "current", RELAY_SIGNING_KEY: "test-key",
    RELAY_KEY_ID: "relay", RELAY_URLS: '["https://relay.example"]',
    ...overrides,
  } as Environment;
}

test("ownership uses the environment Hyperdrive even when a stale direct URL exists", () => {
  const env = environment({
    HYPERDRIVE_CONNECTED_WORKSPACES: { connectionString: "postgres://worker:pass@hyperdrive/database" },
    DATABASE_URL: "invalid-direct-url",
  });
  expect(() => runtime(env)).not.toThrow();
});

test("a malformed Hyperdrive fails closed instead of switching to a direct database", () => {
  const env = environment({
    HYPERDRIVE_CONNECTED_WORKSPACES: { connectionString: "invalid-hyperdrive-url" },
    DATABASE_URL: "postgres://fixture:pass@localhost/fixture",
  });
  expect(() => runtime(env)).toThrow("upstream_unavailable");
});

test("local fixtures can use a direct database without a Hyperdrive binding", () => {
  const env = environment({ ENVIRONMENT: "local", DATABASE_URL: "postgres://fixture:pass@localhost/fixture" });
  expect(() => runtime(env)).not.toThrow();
});
