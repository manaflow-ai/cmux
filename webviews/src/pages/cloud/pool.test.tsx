import { describe, expect, test } from "bun:test";
import {
  hourRateUsd,
  hoursFor,
  hoursOf,
  parseSpendLimit,
  poolOf,
  poolState,
  spendLimitEnabled,
  type PoolStanding,
} from "./pool";
import { MockCloudProvider } from "./mockProvider";
import { CloudStore } from "./store";
import type { CloudPlan } from "./ops";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { PoolPanel } from "./PoolPanel";

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};
async function open(provider: MockCloudProvider) {
  const store = new CloudStore(provider);
  store.subscribe(() => undefined);
  await settle();
  return store;
}
const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };
const render = (store: CloudStore, pool: PoolStanding) =>
  renderToStaticMarkup(<PoolPanel store={store} state={store.getSnapshot()} pool={pool} strings={strings} />);

const POOL = 375 * 240;
const standing = (patch: Partial<PoolStanding> = {}): PoolStanding => ({
  included_minutes: POOL,
  used_minutes: 41 * 240,
  percent: 10,
  warning: null,
  overage_minutes: 0,
  overage_usd: 0,
  spend_limit_usd: 0,
  may_run: true,
  ...patch,
});

describe("pool (RFD 0081 spend limit)", () => {
  test("the switch is off by default and follows the host's attribute over the URL", () => {
    expect(spendLimitEnabled({ dataset: {} }, "")).toBe(false);
    expect(spendLimitEnabled({ dataset: {} }, "?spendLimit=1")).toBe(true);
    expect(spendLimitEnabled({ dataset: { cloudSpendLimit: "off" } }, "?spendLimit=1")).toBe(false);
    expect(spendLimitEnabled({ dataset: { cloudSpendLimit: "on" } }, "")).toBe(true);
  });

  test("hours are counted on the 4 vCPU machine: Plus is 375 hours, $0.08 an hour past it", () => {
    expect(hoursOf(POOL, {})).toBe(375);
    expect(hourRateUsd({})).toBeCloseTo(0.08, 10);
    expect(hoursFor(10, {})).toBe(125);
  });

  test("the state comes from the backend's warning and may_run, never from the page's own math", () => {
    expect(poolState(standing())).toBe("ok");
    expect(poolState(standing({ warning: 80, percent: 82 }))).toBe("near");
    expect(poolState(standing({ warning: 100, percent: 110 }))).toBe("overage");
    expect(poolState(standing({ warning: 100, percent: 100, may_run: false }))).toBe("paused");
  });

  test("a typed limit is parsed like PoolLimit.ts parseSpendLimitUsd", () => {
    expect(parseSpendLimit("0")).toBe(0);
    expect(parseSpendLimit("$12.345")).toBe(12.34);
    expect(parseSpendLimit("1,000")).toBe(1000);
    expect(parseSpendLimit("10000")).toBe(10000);
    expect(parseSpendLimit("10000.01")).toBeNull();
    expect(parseSpendLimit("-1")).toBeNull();
    expect(parseSpendLimit("")).toBeNull();
    expect(parseSpendLimit("ten")).toBeNull();
  });

  test("a plan without a whole pool shows none", () => {
    expect(poolOf(undefined)).toBeUndefined();
    expect(poolOf({ pool: { percent: 3 } } as unknown as CloudPlan)).toBeUndefined();
    expect(poolOf({ pool: standing() } as unknown as CloudPlan)?.percent).toBe(10);
  });

  test("Save runs the setter as a host-confirmed action and reads the plan again", async () => {
    const provider = new MockCloudProvider({ signedIn: true, unsupported: [] });
    provider.pool = standing({ warning: 100, percent: 100, used_minutes: POOL, may_run: false });
    const store = await open(provider);
    await store.setSpendLimit(10);
    const action = provider.calls.find((call) => (call.params as { action?: string })?.action);
    expect((action?.params as { action: string }).action).toBe("cmux.cloud.plan.spend_limit.set");
    expect(poolOf(store.getSnapshot().plan)).toMatchObject({ spend_limit_usd: 10, may_run: true });
    expect(store.getSnapshot().spendLimit).toBeUndefined();
  });

  test("a member who is not an admin is told so", async () => {
    const provider = new MockCloudProvider({ signedIn: true, unsupported: [] });
    provider.pool = standing();
    provider.spendLimitForbidden = true;
    const store = await open(provider);
    await store.setSpendLimit(5);
    expect(store.getSnapshot().spendLimit).toEqual({ saving: false, forbidden: true });
    expect(render(store, standing())).toContain("pool.limitAdminOnly");
  });

  test("the setter's refusals are read from the app server's code or the backend's upstream code", async () => {
    const { spendLimitRefusal } = await import("./pool");
    expect(spendLimitRefusal({ code: "cmux.cloud.spend_limit_forbidden" })).toBe("forbidden");
    expect(spendLimitRefusal({ code: "cmux.cloud.protocol_error", upstream_code: "cloud.spend_limit.off" })).toBe(
      "off",
    );
    expect(spendLimitRefusal({ code: "cmux.cloud.spend_limit_invalid" })).toBe("invalid");
    expect(spendLimitRefusal({ code: "cmux.cloud.forbidden" })).toBe("forbidden");
    expect(spendLimitRefusal(new Error("x"))).toBeUndefined();
  });

  test("a server with the switch off hides nothing and marks the setter not available", async () => {
    const provider = new MockCloudProvider({ signedIn: true, unsupported: [] });
    const store = await open(provider);
    await store.setSpendLimit(5);
    expect(store.getSnapshot().spendLimit).toBeUndefined();
  });

  test("the panel words each state the backend sends", async () => {
    const store = await open(new MockCloudProvider({ signedIn: true, unsupported: [] }));
    const ok = render(store, standing());
    expect(ok).toContain('data-state="ok"');
    expect(ok).not.toContain("pool.near");
    expect(render(store, standing({ warning: 80, percent: 82 }))).toContain("pool.nearBody");
    expect(render(store, standing({ warning: 100, percent: 110, spend_limit_usd: 10 }))).toContain("pool.overage");
    const paused = render(store, standing({ warning: 100, percent: 100, may_run: false }));
    expect(paused).toContain("pool.pausedBody");
    expect(paused).toContain('role="alert"');
  });
});
