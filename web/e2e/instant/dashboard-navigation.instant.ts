import { expect, test } from "@playwright/test";

// A visitor without a Stack session cookie is turned away at the edge. The
// server never renders the dashboard shell for that request, and the browser
// lands on sign-in with the exact destination preserved.
for (const destination of [
  "/dashboard",
  "/dashboard/coderouter",
  "/dashboard/testflight",
  "/dashboard/cloud",
  "/dashboard/billing",
  "/dashboard/billing/success",
  "/dashboard/team",
  "/dashboard/vault",
  "/dashboard/vault/sessions",
  "/dashboard/vault/sessions/not-a-uuid",
  "/dashboard/vault/cli-auth",
  "/dashboard/navigation-fixture",
  "/dashboard/subrouter",
  "/dashboard/ai-accounts",
] as const) {
  test(`${destination} redirects a signed-out visitor before the shell`, async ({
    page,
    request,
  }) => {
    const serverResponse = await request.get(destination, {
      maxRedirects: 0,
    });
    expect(serverResponse.status()).toBe(307);
    const location = serverResponse.headers().location ?? "";
    expect(location).toContain("/handler/sign-in?");
    expect(decodeURIComponent(decodeURIComponent(location))).toContain(destination);
    expect(await serverResponse.text()).not.toContain("dashboard-shell");

    await page.goto(destination);
    await page.waitForURL((url) => url.pathname.startsWith("/handler/sign-in"));
    expect(await page.locator('[data-testid="dashboard-shell"]').count()).toBe(0);
  });
}
