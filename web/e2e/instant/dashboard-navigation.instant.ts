import { expect, test } from "@playwright/test";

const shellSeenKey = "cmux-dashboard-shell-seen-before-auth";

for (const destination of [
  "/dashboard/coderouter",
  "/dashboard/testflight",
] as const) {
  test(`${destination} authenticates before mounting the dashboard shell`, async ({
    page,
    request,
  }) => {
    const serverResponse = await request.get(destination, {
      maxRedirects: 0,
    });
    const serverBody = await serverResponse.text();
    const redirectEvidence = [
      serverResponse.headers().location ?? "",
      serverBody,
    ].join("\n");
    expect(redirectEvidence).toContain("/handler/sign-in?");
    expect(serverBody).not.toContain("dashboard-shell");

    await page.addInitScript(({ key }) => {
      const markDashboardShell = () => {
        if (document.querySelector('[data-testid="dashboard-shell"]')) {
          window.sessionStorage.setItem(key, "true");
        }
      };
      const observer = new MutationObserver(markDashboardShell);
      observer.observe(document, { childList: true, subtree: true });
      window.addEventListener("DOMContentLoaded", markDashboardShell, {
        once: true,
      });
    }, { key: shellSeenKey });

    await page.goto(destination);
    await page.waitForURL((url) => url.pathname.startsWith("/handler/sign-in"));

    expect(
      await page.evaluate((key) => window.sessionStorage.getItem(key), shellSeenKey),
    ).toBeNull();
  });
}
