import { expect, test } from "@playwright/test";

// This route only redirects to the current CodeRouter URL. It gives the test
// a dashboard segment without requiring a Stack session or database state.
const currentDashboardRouteTree = encodeURIComponent(
  JSON.stringify([
    "",
    {
      children: [
        ["locale", "en", "d", null],
        {
          children: [
            "dashboard",
            {
              children: [
                "coderouter",
                { children: ["__PAGE__", {}, null, null] },
                null,
                null,
              ],
            },
            null,
            null,
          ],
        },
        null,
        null,
      ],
    },
    null,
    null,
  ]),
);

test("dashboard keeps its cold fallback out of sibling navigation", async ({
  request,
}) => {
  const appShellResponse = await request.get(
    "/dashboard/subrouter?_rsc=dashboard-prefetch-test",
    {
      headers: {
        RSC: "1",
        "Next-Router-Prefetch": "3",
        "Next-Url": "/dashboard/coderouter",
      },
    },
  );

  expect(appShellResponse.ok()).toBe(true);
  expect(appShellResponse.headers()["content-type"]).toContain("text/x-component");
  const appShellPayload = await appShellResponse.text();
  expect(appShellPayload).not.toContain('"loading":');
  expect(appShellPayload).toContain("animate-pulse");

  const response = await request.get("/dashboard/subrouter?_rsc=dashboard-test", {
    headers: {
      RSC: "1",
      "Next-Router-Prefetch": "3",
      "Next-Url": "/dashboard/coderouter",
      "Next-Router-State-Tree": currentDashboardRouteTree,
    },
  });

  expect(response.ok()).toBe(true);
  expect(response.headers()["content-type"]).toContain("text/x-component");
  const payload = await response.text();
  expect(payload).not.toContain('"loading":');
  expect(payload).not.toContain("animate-pulse");
});
