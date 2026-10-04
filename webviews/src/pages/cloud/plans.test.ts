// "See plans" on the backend's data (f2f84ec1c48): `cloud.plan.required` always offers it; a quota or
// size refusal offers it only when the error's `details.plan` or `CloudPlan.upgrade_plan` names a
// plan (null = no plan lifts the limit). Dev create answers `cloud.no_snapshot_configured` until the
// image lane has a snapshot: the sheet says so in its own words.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pageError } from "../shared/pageClient";
import { MockCloudProvider } from "./mockProvider";
import { CloudErrors, planRefusal } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(provider = new MockCloudProvider()) {
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  return { provider, store };
}

/** The server's mapping of the plan refusal codes (first-party-apps/cloud/server/src/api/error.rs). */
const SERVER_CODE: Record<string, string> = {
  "cloud.plan.required": CloudErrors.planRequired,
  "cloud.quota.exceeded": CloudErrors.quotaExceeded,
  "cloud.size.locked": CloudErrors.sizeLocked,
};

interface VectorError {
  code: string;
  message: string;
  retryable: boolean;
  details?: Record<string, unknown>;
}

/** Every plan refusal in backend/catalog/cloud-vectors.json, as the server hands it to the page. */
function vectorRefusals(): { name: string; error: VectorError }[] {
  const path = join(import.meta.dir, "../../../../backend/catalog/cloud-vectors.json");
  const doc = JSON.parse(readFileSync(path, "utf8")) as {
    cases: { name: string; responses?: { body?: { error?: VectorError } }[] }[];
  };
  return doc.cases.flatMap((c) =>
    (c.responses ?? [])
      .map((r) => r.body?.error)
      .filter((e): e is VectorError => !!e && e.code in SERVER_CODE)
      .map((error) => ({ name: c.name, error })),
  );
}

const asPage = (error: VectorError, details = error.details) =>
  pageError(SERVER_CODE[error.code]!, error.message, error.retryable, details);

describe("See plans on the backend's lifting plan", () => {
  test("every vector refusal offers the plan its details name", () => {
    const refusals = vectorRefusals();
    expect(refusals.map((r) => r.error.code).sort()).toContain("cloud.quota.exceeded");
    expect(refusals.map((r) => r.error.code)).toContain("cloud.size.locked");
    for (const { name, error } of refusals) {
      expect([name, planRefusal(asPage(error), null)?.plan]).toEqual([name, error.details?.plan as string]);
    }
  });

  test("a quota or size refusal with plan null offers no plan, unless the CloudPlan names one", () => {
    for (const { error } of vectorRefusals().filter((r) => r.error.code !== "cloud.plan.required")) {
      const nulled = asPage(error, { ...error.details, plan: null });
      expect(planRefusal(nulled, null)?.plan).toBeUndefined();
      expect(planRefusal(nulled, undefined)?.plan).toBeUndefined();
      expect(planRefusal(nulled, "max")?.plan).toBe("max");
    }
  });

  test("the store passes CloudPlan.upgrade_plan to a quota refusal without its own plan", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_active = 3;
    provider.account.plan.upgrade_plan = "max";
    const { store } = await started(provider);
    expect(store.getSnapshot().plan?.upgrade_plan).toBe("max");
    store.openCreate();
    await store.submitCreate();
    expect(store.getSnapshot().create?.refusal).toEqual({ kind: "quota_exceeded", limit: 3, used: 3, plan: "max" });
  });

  test("the error's own plan wins over CloudPlan.upgrade_plan", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_active = 3;
    provider.account.plan.upgrade_plan = "max";
    provider.liftingPlan = "pro";
    const { store } = await started(provider);
    store.openCreate();
    await store.submitCreate();
    expect(store.getSnapshot().create?.refusal?.plan).toBe("pro");
  });

  test("dev and staging today: no lifting plan anywhere, so no See plans for a quota refusal", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_active = 3;
    const { store } = await started(provider);
    expect(store.getSnapshot().plan?.upgrade_plan).toBeNull();
    store.openCreate();
    await store.submitCreate();
    expect(store.getSnapshot().create?.refusal?.plan).toBeUndefined();
  });
});

describe("no machine image configured", () => {
  test("a create the backend cannot serve yet says so in the sheet, not as a raw error", async () => {
    const provider = new MockCloudProvider();
    provider.noSnapshotConfigured = true;
    const { store } = await started(provider);
    store.openCreate();
    await store.submitCreate();
    const draft = store.getSnapshot().create!;
    expect(draft.blocked).toBe("no_snapshot_configured");
    expect(draft.error).toBeUndefined();
    expect(draft.refusal).toBeUndefined();
    expect(draft.submitting).toBe(false);
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().pending).toEqual([]);
  });

  test("a restore the backend cannot serve yet shows the same sentence on the page, not the raw error", async () => {
    const provider = new MockCloudProvider();
    provider.noSnapshotConfigured = true;
    const { store } = await started(provider);
    await store.restoreSnapshot(provider.snapshots[0]!);
    expect(store.getSnapshot().blocked).toBe("no_snapshot_configured");
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().refusal).toBeUndefined();
    expect(store.getSnapshot().pending).toEqual([]);
    store.dismissError();
    expect(store.getSnapshot().blocked).toBeUndefined();
  });
});
