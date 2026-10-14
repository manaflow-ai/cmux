import { describe, expect, test } from "bun:test";
import { NextIntlClientProvider } from "next-intl";
import { RequiresPro } from "../dashboard-app/components/requires-pro";
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

async function renderCloud(plan?: Plan, search = "") {
  const queryClient = createScreenQueryClient();
  if (plan) queryClient.setQueryData(planQuery.queryKey, plan);
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
