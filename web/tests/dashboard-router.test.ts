import { describe, expect, test } from "bun:test";
import { createMemoryHistory, createRouter } from "@tanstack/react-router";
import { QueryClient } from "@tanstack/react-query";

import { routeTree } from "../app/[locale]/dashboard/dashboard-router";

const context = {
  queryClient: new QueryClient(),
  vaultEnabled: true,
  account: null,
  initialContent: null,
  locale: "en",
};

describe("dashboard TanStack Router", () => {
  test("declares every dashboard URL, including legacy redirects", () => {
    const router = createRouter({
      routeTree,
      basepath: "/en/dashboard",
      history: createMemoryHistory({ initialEntries: ["/en/dashboard/"] }),
      context,
    });

    expect(Object.keys(router.routesByPath)).toEqual([
      "/",
      "/cloud",
      "/coderouter",
      "/testflight",
      "/billing",
      "/billing/success",
      "/team",
      "/vault",
      "/vault/sessions",
      "/vault/sessions/$id",
      "/vault/cli-auth",
      "/navigation-fixture",
      "/subrouter",
      "/ai-accounts",
    ]);
  });

  test("resolves links against the localized dashboard mount", () => {
    const router = createRouter({
      routeTree,
      basepath: "/ja/dashboard",
      history: createMemoryHistory({ initialEntries: ["/ja/dashboard/"] }),
      context,
    });

    expect(router.buildLocation({ to: "/cloud" }).href).toBe("/ja/dashboard/cloud");
  });
});
