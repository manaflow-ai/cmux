import { describe, expect, test } from "bun:test";

import { coderouterHealth, type HealthDependencies } from "../services/coderouter/health";

const configured = {
  CODEROUTER_KMS_KEY_ID: "alias/test",
  AWS_REGION: "us-west-2",
};

function dependencies(overrides: Partial<HealthDependencies> = {}): HealthDependencies {
  return {
    pingPostgres: async () => undefined,
    pingClickHouse: async () => ({ ok: true }),
    env: configured,
    timeoutMs: 200,
    ...overrides,
  };
}

describe("coderouterHealth", () => {
  test("is ok when every dependency answers", async () => {
    const health = await coderouterHealth(dependencies());
    expect(health.status).toBe("ok");
    expect(health.checks.map((check) => [check.name, check.ok])).toEqual([
      ["postgres", true],
      ["clickhouse", true],
      ["kms_config", true],
    ]);
    expect(typeof health.checks[0]!.latencyMs).toBe("number");
  });

  test("a failing non-critical dependency degrades, a critical one takes it down", async () => {
    const degraded = await coderouterHealth(dependencies({
      pingClickHouse: async () => ({ ok: false, reason: "http_503" }),
    }));
    expect(degraded.status).toBe("degraded");
    expect(degraded.checks.find((check) => check.name === "clickhouse")).toMatchObject({ ok: false, reason: "http_503" });

    const down = await coderouterHealth(dependencies({
      pingPostgres: async () => {
        throw Object.assign(new Error("password authentication failed for user secret"), { name: "PostgresError" });
      },
    }));
    expect(down.status).toBe("down");
    // Only the error class leaves the process, never the message.
    expect(down.checks[0]).toMatchObject({ name: "postgres", ok: false, reason: "PostgresError" });
  });

  test("a hung dependency reports a timeout instead of hanging the probe", async () => {
    const health = await coderouterHealth(dependencies({
      pingPostgres: () => new Promise(() => undefined),
      timeoutMs: 20,
    }));
    expect(health.status).toBe("down");
    expect(health.checks[0]).toMatchObject({ name: "postgres", ok: false, reason: "timeout" });
  });

  test("missing KMS configuration is critical", async () => {
    const health = await coderouterHealth(dependencies({ env: { ...configured, AWS_REGION: "" } }));
    expect(health.status).toBe("down");
    expect(health.checks.find((check) => check.name === "kms_config")).toMatchObject({ ok: false, reason: "missing_kms_key_id_or_region" });
  });
});
