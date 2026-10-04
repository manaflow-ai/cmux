import { describe, expect, test } from "bun:test";
import {
  categories,
  categoryLabel,
  dimmedWhenSandboxed,
  filterApps,
  initials,
  matches,
  orderScopes,
  parseRoute,
} from "./model";
import { sampleApps } from "./mockProvider";
import type { CatalogApp } from "./types";

const apps = Object.values(sampleApps().details) as CatalogApp[];

describe("routes", () => {
  test("tab, layout and app come from the fragment; unknown values fall back", () => {
    expect(parseRoute("")).toEqual({ tab: "discover", layout: "grid", app: undefined });
    expect(parseRoute("#/installed")).toMatchObject({ tab: "installed" });
    expect(parseRoute("#/discover?layout=split&app=cmux.coderouter")).toEqual({
      tab: "discover",
      layout: "split",
      app: "cmux.coderouter",
    });
    expect(parseRoute("#/discover?layout=carousel")).toMatchObject({ layout: "grid" });
  });
});

describe("search and categories (Swift AppStoreListing.matches)", () => {
  test("every word must match id, name, description, publisher, categories or keywords", () => {
    const github = apps.find((app) => app.id === "cmux.github-prs")!;
    expect(matches(github, "")).toBe(true);
    expect(matches(github, "PULL review")).toBe(true);
    expect(matches(github, "git cmux")).toBe(true);
    expect(matches(github, "github weather")).toBe(false);
  });

  test("category and query filter together; categories keep first-seen order", () => {
    expect(filterApps(apps, "", "agents").map((app) => app.id)).toEqual(["cmux.coderouter"]);
    expect(filterApps(apps, "awake", undefined).map((app) => app.id)).toEqual(["acme.caffeinate"]);
    expect(categories(apps)).toEqual(["sidebar", "git", "agents", "productivity", "fun"]);
    expect(categoryLabel("developer-tools", (key) => `<${key}>`)).toBe("<store.category.developerTools>");
    expect(categoryLabel("custom", (key) => key)).toBe("custom");
  });
});

describe("permissions", () => {
  test("required before optional, then the riskiest first", () => {
    const ordered = orderScopes([
      { scope: "b:read", risk: "read", optional: false },
      { scope: "net:x", risk: "network", optional: true },
      { scope: "a:write", risk: "mutate", optional: false },
      { scope: "integration:y", risk: "integration", optional: false },
    ] as const);
    expect(ordered.map((scope) => scope.scope)).toEqual(["integration:y", "a:write", "b:read", "net:x"]);
  });

  test("network and integration rows dim while sandboxed", () => {
    expect(dimmedWhenSandboxed({ scope: "net:a", reason: "", risk: "network", optional: false, granted: true })).toBe(
      true,
    );
    expect(
      dimmedWhenSandboxed({ scope: "workspace:read", reason: "", risk: "read", optional: false, granted: true }),
    ).toBe(false);
  });

  test("glyph initials", () => {
    expect(initials("GitHub PRs")).toBe("GP");
    expect(initials("Caffeinate")).toBe("CA");
    expect(initials(" ")).toBe("?");
  });
});
