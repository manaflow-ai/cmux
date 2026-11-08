import { describe, expect, test } from "bun:test";

import {
  coderouterHealth,
  createCachedCoderouterHealthProbe,
  type HealthDependencies,
  type HealthScheduler,
} from "../services/coderouter/health";

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

function manualScheduler(): HealthScheduler & { fire: () => void } {
  const timers = new Set<() => void>();
  return {
    now: () => 0,
    setTimeout: (callback) => {
      timers.add(callback);
      return callback;
    },
    clearTimeout: (handle) => {
      if (typeof handle === "function") timers.delete(handle as () => void);
    },
    fire: () => {
      for (const callback of [...timers]) {
        timers.delete(callback);
        callback();
      }
    },
  };
}

describe("coderouterHealth", () => {
  test("coalesces concurrent probes and caches only for the configured short window", async () => {
    let now = 0;
    let calls = 0;
    const probe = createCachedCoderouterHealthProbe(async () => {
      calls += 1;
      return coderouterHealth(dependencies());
    }, { now: () => now, ttlMs: 5_000 });

    const first = probe();
    const second = probe();
    await Promise.all([first, second]);
    expect(calls).toBe(1);

    now = 4_999;
    await probe();
    expect(calls).toBe(1);
    now = 5_000;
    await probe();
    expect(calls).toBe(2);
  });

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
    // The public health body contains only a stable reason, never the error
    // class or message. The class is retained in the internal breadcrumb.
    expect(down.checks[0]).toMatchObject({ name: "postgres", ok: false, reason: "probe_failed" });
    expect(JSON.stringify(down)).not.toContain("PostgresError");
  });

  test("a hung dependency reports a timeout instead of hanging the probe", async () => {
    const scheduler = manualScheduler();
    const pending = coderouterHealth(dependencies({
      pingPostgres: () => new Promise(() => undefined),
      timeoutMs: 20,
      scheduler,
    }));
    await Promise.resolve();
    scheduler.fire();
    const health = await pending;
    expect(health.status).toBe("down");
    expect(health.checks[0]).toMatchObject({ name: "postgres", ok: false, reason: "timeout" });
  });

  test("aborts a dependency when its health budget expires", async () => {
    let observedSignal: AbortSignal | undefined;
    const scheduler = manualScheduler();
    const pending = coderouterHealth(dependencies({
      pingPostgres: (signal) => {
        observedSignal = signal;
        return new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(new Error("probe aborted")), { once: true });
        });
      },
      timeoutMs: 20,
      scheduler,
    }));
    await Promise.resolve();
    scheduler.fire();
    const health = await pending;
    expect(health.checks[0]).toMatchObject({ name: "postgres", ok: false, reason: "timeout" });
    expect(observedSignal?.aborted).toBe(true);
  });

  test("missing KMS configuration is critical", async () => {
    const health = await coderouterHealth(dependencies({ env: { ...configured, AWS_REGION: "" } }));
    expect(health.status).toBe("down");
    expect(health.checks.find((check) => check.name === "kms_config")).toMatchObject({ ok: false, reason: "missing_kms_key_id_or_region" });
  });
});
