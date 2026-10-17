import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import type { PaywallChange, PaywallRun } from "../services/billing/paywall/store";

type StackUser = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  isAnonymous: boolean;
};

let currentUser: StackUser | null = null;
const getUser = mock(async () => currentUser);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser },
}));
mock.module("../services/admin/members", () => ({
  findActiveAdminMember: async () => null,
}));

// The experiment log is Postgres in production; here it is in memory.
let changes: (PaywallChange & { changedAt: Date })[] = [];
let runs: PaywallRun[] = [];
const realStore = await import("../services/billing/paywall/store");
mock.module("../services/billing/paywall/store", () => ({
  ...realStore,
  databasePaywallExperimentLog: () => ({
    appendChanges: async (next: readonly PaywallChange[]) => {
      changes.push(...next.map((change) => ({ ...change, changedAt: change.changedAt ?? new Date("2026-10-15T12:00:00Z") })));
    },
    recordRun: async (run: PaywallRun) => {
      runs.push(run);
    },
    latestRun: async (experiment: string) => runs.filter((run) => run.experiment === experiment).at(-1) ?? null,
    changes: async (experiment: string) => changes.filter((change) => change.experiment === experiment),
    lastChangeAt: async () => null,
  }),
}));

// PostHog's feature-flag API.
type Flag = { id: number; key: string; active: boolean; deleted: boolean; filters: Record<string, unknown> };
let flags: Flag[] = [];
const patches: { id: number; body: unknown }[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = new URL(String(input));
  if (!url.hostname.endsWith("posthog.com")) return realFetch(input, init);
  const patch = url.pathname.match(/\/feature_flags\/(\d+)\/$/);
  if (patch && init?.method === "PATCH") {
    const body = JSON.parse(String(init.body)) as { active: boolean };
    patches.push({ id: Number(patch[1]), body });
    const flag = flags.find((item) => item.id === Number(patch[1]));
    if (!flag) return new Response("{}", { status: 404 });
    flag.active = body.active;
    return Response.json(flag);
  }
  return Response.json({ results: flags });
}) as typeof fetch;
process.env.POSTHOG_PERSONAL_API_KEY = "phx_test";

const { GET, POST } = await import("../app/api/admin/paywall-lab/route");

afterAll(() => {
  globalThis.fetch = realFetch;
});

function staff(): StackUser {
  return { id: "staff-1", primaryEmail: "lab@manaflow.ai", primaryEmailVerified: true, isAnonymous: false };
}

function webFlag(): Flag {
  return {
    id: 42,
    key: "web-pricing-v1",
    active: true,
    deleted: false,
    filters: {
      groups: [{ properties: [], rollout_percentage: 100 }],
      multivariate: {
        variants: [
          { key: "control", rollout_percentage: 40 },
          { key: "yearly-emphasis", rollout_percentage: 30 },
          { key: "highlight-pro", rollout_percentage: 30 },
          { key: "outcome-headline", rollout_percentage: 0 },
        ],
      },
    },
  };
}

function pauseRequest(body: unknown, origin = "https://cmux.com") {
  return new NextRequest("https://cmux.com/api/admin/paywall-lab", {
    method: "POST",
    headers: { origin, "content-type": "application/json", "sec-fetch-site": "same-origin" },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  currentUser = null;
  changes = [];
  runs = [];
  flags = [webFlag()];
  patches.length = 0;
});

describe("Paywall Lab staff route", () => {
  test("signed-out callers get 401 and regular users get 403", async () => {
    expect((await GET(new NextRequest("https://cmux.com/api/admin/paywall-lab"))).status).toBe(401);
    currentUser = { ...staff(), primaryEmail: "someone@example.com" };
    expect((await GET(new NextRequest("https://cmux.com/api/admin/paywall-lab"))).status).toBe(403);
    expect((await POST(pauseRequest({ experiment: "web-pricing-v1", paused: true }))).status).toBe(403);
    expect(patches).toHaveLength(0);
  });

  test("staff see both experiments, every arm rendered from validated copy, and the optimizer's numbers", async () => {
    currentUser = staff();
    runs.push({
      experiment: "web-pricing-v1",
      ranAt: new Date("2026-10-16T06:00:00Z"),
      halted: false,
      reportMarkdown: "# web-pricing-v1 optimizer report\n",
      snapshot: {
        experiment: "web-pricing-v1",
        platform: "web",
        flagFound: true,
        dryRun: false,
        allocationApplied: true,
        allocationSince: "2026-10-15T00:00:00Z",
        decision: {
          current: {}, target: {}, probabilityBest: {}, retire: [], halted: false, changed: true,
          reasons: ["Thompson sampling: traffic follows P(best), control floor 10%"],
          srm: { tested: true, chiSquare: 1.2, pValue: 0.55, mismatch: false },
        },
        variants: [
          { variant: "control", name: null, status: "live", rolloutBefore: 25, rolloutAfter: 40, exposures: 120, conversions: 2, probabilityBest: 0.3, secondary: { checkout_started: 9 }, guardrails: { refunded: 0 }, payload: null, payloadHash: null, payloadErrors: [] },
          { variant: "outcome-headline", name: null, status: "retired", rolloutBefore: 25, rolloutAfter: 0, exposures: 330, conversions: 0, probabilityBest: 0.01, secondary: {}, guardrails: {}, payload: null, payloadHash: null, payloadErrors: [] },
        ],
      },
    });

    const response = await GET(new NextRequest("https://cmux.com/api/admin/paywall-lab"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json() as {
      experiments: { key: string; flagState: string; hasReport: boolean; srm: { tested: boolean; pValue: number }; variants: { variant: string; status: string; exposures: number | null; secondary: Record<string, number>; preview: { kind: string; presentation?: { highlightedPlanId: string | null } } | null }[] }[];
    };
    expect(body.experiments.map((experiment) => experiment.key)).toEqual(["ios-paywall-v1", "web-pricing-v1"]);
    const web = body.experiments.find((experiment) => experiment.key === "web-pricing-v1")!;
    expect(web.flagState).toBe("live");
    expect(web.hasReport).toBe(true);
    expect(web.srm).toMatchObject({ tested: true, pValue: 0.55 });
    expect(web.variants.find((variant) => variant.variant === "control")).toMatchObject({ exposures: 120, secondary: { checkout_started: 9 }, preview: { kind: "web" } });
    expect(web.variants.find((variant) => variant.variant === "outcome-headline")).toMatchObject({ status: "retired" });
    const ios = body.experiments.find((experiment) => experiment.key === "ios-paywall-v1")!;
    expect(ios.variants.length).toBeGreaterThan(0);
    expect(ios.variants.every((variant) => variant.preview?.kind === "ios")).toBe(true);
  });

  test("the kill switch turns the flag off, logs who did it, and resume turns it back on", async () => {
    currentUser = staff();

    const paused = await POST(pauseRequest({ experiment: "web-pricing-v1", paused: true }));
    expect(paused.status).toBe(200);
    expect(await paused.json()).toEqual({ ok: true, flagState: "paused" });
    expect(patches).toEqual([{ id: 42, body: { active: false } }]);
    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({
      experiment: "web-pricing-v1",
      kind: "allocation_changed",
      actor: "staff:lab@manaflow.ai",
      details: { paused: true, split: { control: 40, "yearly-emphasis": 30, "highlight-pro": 30, "outcome-headline": 0 } },
    });

    const view = await (await GET(new NextRequest("https://cmux.com/api/admin/paywall-lab"))).json() as { experiments: { key: string; flagState: string }[] };
    expect(view.experiments.find((experiment) => experiment.key === "web-pricing-v1")!.flagState).toBe("paused");

    const resumed = await POST(pauseRequest({ experiment: "web-pricing-v1", paused: false }));
    expect(await resumed.json()).toEqual({ ok: true, flagState: "live" });
    expect(patches.at(-1)).toEqual({ id: 42, body: { active: true } });
    expect(changes).toHaveLength(2);
  });

  test("the kill switch refuses a cross-site request and an unknown experiment", async () => {
    currentUser = staff();
    expect((await POST(pauseRequest({ experiment: "web-pricing-v1", paused: true }, "https://evil.example"))).status).toBe(403);
    expect((await POST(pauseRequest({ experiment: "nope", paused: true }))).status).toBe(404);
    expect(patches).toHaveLength(0);
    expect(changes).toHaveLength(0);
  });
});
