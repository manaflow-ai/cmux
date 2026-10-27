import { describe, expect, test } from "bun:test";
import { NextIntlClientProvider } from "next-intl";
import { type QueryClient, QueryObserver } from "@tanstack/react-query";
import { planPromptOutdated, planPromptQuery, RequiresPro } from "../dashboard-app/components/requires-pro";
import { planQuery } from "../dashboard-app/queries/billing";
import { CloudPageFrame } from "../dashboard-app/screens/cloud/cloud-frame";
import enMessages from "../messages/en.json";
import { createScreenQueryClient, renderDashboardScreen } from "./helpers/dashboard-spa-render";

type Plan = {
  readonly planId: "free" | "go" | "pro" | "max";
  readonly isPro: boolean;
  readonly billingManagement: "stripe" | "external" | "none";
  readonly teamPlanId: "free" | "team";
};

const free: Plan = { planId: "free", isPro: false, billingManagement: "none", teamPlanId: "free" };
const team: Plan = { ...free, teamPlanId: "team" };

/** Seed billing state and render the production Cloud frame at the requested URL. */
async function renderCloud(plan?: Plan, search = "") {
  const queryClient = createScreenQueryClient();
  if (plan) queryClient.setQueryData(planQuery.queryKey, plan);
  return renderCloudWithClient(queryClient, search);
}

/** Reuse a cache across refresh transitions so the frame observes real query state. */
async function renderCloudWithClient(queryClient: QueryClient, search = "") {
  return renderDashboardScreen({
    url: `/dashboard/cloud${search}`,
    queryClient,
    render: () => (
      <NextIntlClientProvider locale="en" messages={enMessages} timeZone="UTC">
        <CloudPageFrame><p>Cloud machines</p></CloudPageFrame>
      </NextIntlClientProvider>
    ),
  });
}

describe("dashboard Cloud plan prompt", () => {
  test("a Team subscriber without a personal plan is not asked to buy Pro", async () => {
    const html = await renderCloud(team);
    expect(html).toContain("Cloud machines");
    expect(html).not.toContain('data-testid="requires-pro"');
    expect(html).not.toContain("plan=pro");
  });

  test("a Free viewer gets checkout that returns to Cloud", async () => {
    const html = await renderCloud(free);
    expect(html).toContain('data-testid="requires-pro"');
    expect(html).toContain("returnTo=%2Fdashboard%2Fcloud");
    expect(html).toContain("plan=pro");
  });

  test.each(["go", "pro", "max"] as const)("a personal %s plan keeps Cloud access", async (planId) => {
    const html = await renderCloud({ ...free, planId, isPro: true, billingManagement: "stripe" });
    expect(html).not.toContain('data-testid="requires-pro"');
  });

  test("unknown plan state keeps the Cloud page visible without a purchase prompt", async () => {
    const html = await renderCloud();
    expect(html).toContain("Cloud machines");
    expect(html).not.toContain('data-testid="requires-pro"');
  });

  test("a Team plan does not confirm a stale personal checkout welcome", async () => {
    const html = await renderCloud(team, "?welcome=pro");
    expect(html).not.toContain('data-testid="requires-pro"');
    expect(html).not.toContain('data-testid="plan-welcome"');
  });

  test.each([
    { name: "Free to Team", previous: free, next: team },
    { name: "Team to Free", previous: team, next: free },
  ])("a $name switch waits for the current team's plan", async ({ previous, next }) => {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(planQuery.queryKey, previous);
    const before = await renderCloudWithClient(queryClient);
    expect(before.includes('data-testid="requires-pro"')).toBe(previous.teamPlanId === "free");

    // A team switch invalidates every dashboard query before refetching.
    await queryClient.invalidateQueries({ queryKey: planQuery.queryKey, refetchType: "none" });
    let finish!: (plan: Plan) => void;
    const response = new Promise<Plan>((resolve) => { finish = resolve; });
    const refresh = queryClient.fetchQuery({ ...planQuery, staleTime: 0, queryFn: () => response });
    try {
      const pending = await renderCloudWithClient(queryClient);
      expect(pending).toContain("Cloud machines");
      expect(pending).not.toContain('data-testid="requires-pro"');
    } finally {
      finish(next);
      await refresh;
    }

    const after = await renderCloudWithClient(queryClient);
    expect(after.includes('data-testid="requires-pro"')).toBe(next.teamPlanId === "free");
    queryClient.clear();
  });

  test.each([
    { name: "Free to Team", previous: free },
    { name: "Team to Free", previous: team },
  ])("a failed $name reload does not show the previous team's answer", async ({ previous }) => {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(planQuery.queryKey, previous);
    await queryClient.invalidateQueries({ queryKey: planQuery.queryKey, refetchType: "none" });
    const reload = queryClient.fetchQuery({ ...planQuery, staleTime: 0, queryFn: () => Promise.reject(new Error("plan unavailable")) });
    await expect(reload).rejects.toThrow("plan unavailable");

    const html = await renderCloudWithClient(queryClient);
    expect(html).toContain("Cloud machines");
    expect(html).not.toContain('data-testid="requires-pro"');
    queryClient.clear();
  });

  test("the prompt re-renders through a team switch reload, whether it succeeds unchanged or fails", async () => {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(planQuery.queryKey, free);
    let respond: () => Promise<Plan> = () => Promise.resolve({ ...free });
    // The same options RequiresPro passes to useQuery, with a controllable response.
    const observer = new QueryObserver(queryClient, { ...planPromptQuery, queryFn: () => respond() });
    // React tracks the result fields a component reads; RequiresPro reads only the plan data.
    void observer.trackResult(observer.getCurrentResult()).data;
    // Each entry is what RequiresPro renders after a re-render: hidden while the plan is outdated.
    const renders: boolean[] = [];
    const unsubscribe = observer.subscribe(() => renders.push(planPromptOutdated(queryClient)));
    try {
      // A switch between two Free teams: the reload returns an equal plan.
      await queryClient.invalidateQueries({ queryKey: planQuery.queryKey });
      expect(renders).toContain(true);
      expect(renders.at(-1)).toBe(false);

      // A switch whose reload fails must not bring back the previous team's answer.
      renders.length = 0;
      respond = () => Promise.reject(new Error("plan unavailable"));
      await queryClient.invalidateQueries({ queryKey: planQuery.queryKey });
      expect(renders.at(-1)).toBe(true);

      // The next good reload shows the prompt again.
      renders.length = 0;
      respond = () => Promise.resolve({ ...free });
      await queryClient.refetchQueries({ queryKey: planQuery.queryKey });
      expect(renders.at(-1)).toBe(false);
    } finally {
      unsubscribe();
      queryClient.clear();
    }
  });

  test("a Cloud refresh does not confirm a welcome from the previous personal plan", async () => {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(planQuery.queryKey, { ...free, planId: "pro", isPro: true });
    expect(await renderCloudWithClient(queryClient, "?welcome=pro")).toContain('data-testid="plan-welcome"');

    await queryClient.invalidateQueries({ queryKey: planQuery.queryKey, refetchType: "none" });
    let finish!: (plan: Plan) => void;
    const response = new Promise<Plan>((resolve) => { finish = resolve; });
    const refresh = queryClient.fetchQuery({ ...planQuery, staleTime: 0, queryFn: () => response });
    try {
      const pending = await renderCloudWithClient(queryClient, "?welcome=pro");
      expect(pending).not.toContain('data-testid="plan-welcome"');
      expect(pending).not.toContain('data-testid="requires-pro"');
    } finally {
      finish(free);
      await refresh;
    }

    expect(await renderCloudWithClient(queryClient, "?welcome=pro")).toContain('data-testid="requires-pro"');
    queryClient.clear();
  });

  test("a background refetch keeps the Free prompt in place", async () => {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(planQuery.queryKey, free);

    // Window focus refetches a stale plan without invalidating it; the
    // prompt must not disappear and reappear around that request.
    let finish!: (plan: Plan) => void;
    const response = new Promise<Plan>((resolve) => { finish = resolve; });
    const refetch = queryClient.fetchQuery({ ...planQuery, staleTime: 0, queryFn: () => response });
    try {
      expect(await renderCloudWithClient(queryClient)).toContain('data-testid="requires-pro"');
    } finally {
      finish(free);
      await refetch;
    }
    queryClient.clear();
  });

  test.each(["testflight", "mobileDevices"] as const)("Team Cloud access does not change the personal %s prompt", async (feature) => {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(planQuery.queryKey, team);
    const html = await renderDashboardScreen({
      url: `/dashboard/${feature}`,
      queryClient,
      render: () => (
        <NextIntlClientProvider locale="en" messages={enMessages} timeZone="UTC">
          <RequiresPro feature={feature} />
        </NextIntlClientProvider>
      ),
    });
    expect(html).toContain('data-testid="requires-pro"');
  });
});
