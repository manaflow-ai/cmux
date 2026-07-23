import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { loadMessages } from "../i18n/messages";
import {
  canEnterCloudPortal,
  resolveHomePortalPaths,
} from "../app/[locale]/home/portal-routing";

const webDir = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("authenticated cloud portal routing", () => {
  test("pins a post-incident TanStack Router release and excludes known malware versions", async () => {
    const packageJson = JSON.parse(await readFile(join(webDir, "package.json"), "utf8")) as {
      dependencies: Record<string, string>;
    };
    const lockfile = await readFile(join(webDir, "bun.lock"), "utf8");

    expect(packageJson.dependencies["@tanstack/react-router"]).toBe("1.170.18");
    expect(lockfile).toContain("@tanstack/react-router@1.170.18");
    expect(lockfile).not.toContain("@tanstack/react-router@1.169.5");
    expect(lockfile).not.toContain("@tanstack/react-router@1.169.8");
    expect(lockfile).not.toContain("@tanstack/setup");
    expect(lockfile).not.toContain("router_init.js");
  });

  test("uses Next only for the authenticated home boundary and isolated TanStack history for portal views", async () => {
    const page = await readFile(join(webDir, "app", "[locale]", "home", "[[...portal]]", "page.tsx"), "utf8");
    const portal = await readFile(join(webDir, "app", "[locale]", "dashboard", "cloud", "cloud-portal.tsx"), "utf8");

    expect(page).toContain("<CloudPortal");
    expect(portal).toContain("createRouter({");
    expect(portal).toContain("createMemoryHistory({ initialEntries: [initialPath] })");
    expect(portal).not.toContain("createBrowserHistory");
    expect(portal).toContain("useSyncExternalStore");
    expect(portal).toContain("isClient ? <RouterProvider");
    expect(portal).toContain('path: "/activity"');
    expect(portal).toContain('path: "/machines/$machineId"');
    expect(portal).toContain("<RouterProvider router={router} />");
    expect(portal).toContain("<Tabs.Root");
    expect(portal).toContain("<Tabs.List activateOnFocus");
    expect(portal).toContain("<Tabs.Tab");
  });

  test("rejects signed-out and anonymous users at the home boundary", () => {
    expect(canEnterCloudPortal(null)).toBeFalse();
    expect(canEnterCloudPortal({ isAnonymous: true })).toBeFalse();
    expect(canEnterCloudPortal({ isAnonymous: false })).toBeTrue();
  });

  test("preserves supported portal subroutes through authentication", () => {
    expect(resolveHomePortalPaths()).toEqual({ initialPath: "/", returnPath: "/home" });
    expect(resolveHomePortalPaths(["activity"])).toEqual({
      initialPath: "/activity",
      returnPath: "/home/activity",
    });
    expect(resolveHomePortalPaths(["machines", "vm/unsafe"])).toEqual({
      initialPath: "/machines/vm%2Funsafe",
      returnPath: "/home/machines/vm%2Funsafe",
    });
  });

  test("falls back to the complete English portal catalog for other locales", async () => {
    const messages = await loadMessages("fr");
    const cloud = (messages.dashboard as { cloud: { title: string } }).cloud;

    expect(cloud.title).toBe("Cloud workspace");
  });
});
