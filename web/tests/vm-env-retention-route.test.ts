import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const workflows = await import("../services/vms/workflows");
const cleanupEnvLayers = mock(() => ({} as ReturnType<typeof workflows.cleanupEnvLayers>));
const runVmWorkflow = mock(async () => ({
  candidates: 1,
  deleted: 1,
  failed: 0,
  backlog: false,
}));

mock.module("../services/vms/workflows", () => ({
  ...workflows,
  cleanupEnvLayers,
  runVmWorkflow,
}));

const { GET } = await import("../app/api/cron/vm-env-retention/route");
const originalCronSecret = process.env.CRON_SECRET;

beforeEach(() => {
  process.env.CRON_SECRET = "cron-secret";
  cleanupEnvLayers.mockClear();
  runVmWorkflow.mockClear();
});

afterEach(() => {
  if (originalCronSecret === undefined) delete process.env.CRON_SECRET;
  else process.env.CRON_SECRET = originalCronSecret;
});

describe("env-layer retention cron", () => {
  test("rejects requests without the cron secret before cleanup", async () => {
    const response = await GET(new Request("https://cmux.test/api/cron/vm-env-retention"));
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(cleanupEnvLayers).not.toHaveBeenCalled();
  });

  test("runs cleanup for a valid cron bearer secret", async () => {
    const response = await GET(new Request("https://cmux.test/api/cron/vm-env-retention", {
      headers: { authorization: "Bearer cron-secret" },
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      retention: { candidates: 1, deleted: 1, failed: 0, backlog: false },
    });
    expect(cleanupEnvLayers).toHaveBeenCalledTimes(1);
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
  });
});
