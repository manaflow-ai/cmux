import { expect, test } from "@playwright/test";

// This route only redirects to the current CodeRouter URL. It gives the test
// a dashboard segment without requiring a Stack session or database state.
const dashboardLoadingBoundary =
  '"loading":[["$","div","l",{"aria-hidden":"true","className":"mx-auto w-full max-w-5xl px-3 py-4"';

test("dashboard navigation payload has no dashboard-wide loading fallback", async ({
  request,
}) => {
  const response = await request.get("/dashboard/subrouter?_rsc=dashboard-test", {
    headers: {
      RSC: "1",
      "Next-Router-Prefetch": "3",
      "Next-Url": "/dashboard/coderouter",
    },
  });

  expect(response.ok()).toBe(true);
  const payload = await response.text();
  expect(payload).not.toContain(dashboardLoadingBoundary);
});
