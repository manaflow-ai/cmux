import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { AppPricingContent, type AppPlanSnapshot } from "../app/app-pricing/pricing-content";

const cancelScheduledPro: AppPlanSnapshot = {
  userId: "user_1",
  authenticated: true,
  developmentPro: false,
  planId: "pro",
  isPro: true,
  billingManagement: "stripe",
  billingSource: "stripe",
  cancelScheduled: true,
  email: "buyer@example.com",
};

function render(snapshot: AppPlanSnapshot) {
  return renderToStaticMarkup(
    <AppPricingContent
      params={{ cmux_app: "1" }}
      headersList={new Headers({ host: "cmux.test" })}
      snapshot={snapshot}
      goPlanEnabled={false}
      section="individual"
    />,
  );
}

describe("app pricing for a subscriber who cancelled", () => {
  test("offers Resume on the current plan while the cancellation is scheduled", () => {
    const html = render(cancelScheduledPro);
    expect(html).toMatch(/<form[^>]*action="\/api\/billing\/subscription"[^>]*method="post"|<form[^>]*method="post"[^>]*action="\/api\/billing\/subscription"/);
    expect(html).toContain('name="action" value="resume"');
    expect(html).toContain("Resume Pro");
  });

  test("keeps Manage billing for an active subscription", () => {
    const html = render({ ...cancelScheduledPro, cancelScheduled: false });
    expect(html).not.toContain("Resume Pro");
    expect(html).toContain("Manage billing");
  });
});

describe("app pricing for an App Store subscription that can still charge", () => {
  test("offers Manage in the App Store instead of Stripe checkout", () => {
    const html = render({
      authenticated: true,
      developmentPro: false,
      planId: "free",
      isPro: false,
      billingManagement: "none",
      billingSource: "none",
      appStoreSubscription: true,
      email: "buyer@example.com",
    });
    expect(html).toContain("https://apps.apple.com/account/subscriptions");
    expect(html).not.toContain("/api/billing/checkout");
  });

  test("a free account without one still gets checkout", () => {
    const html = render({
      authenticated: true,
      developmentPro: false,
      planId: "free",
      isPro: false,
      billingManagement: "none",
      billingSource: "none",
      email: "buyer@example.com",
    });
    expect(html).not.toContain("https://apps.apple.com/account/subscriptions");
    expect(html).toContain("/api/billing/checkout");
  });
});
