import { describe, expect, test } from "bun:test";
import { isRemovable } from "./model";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import { AppsOps } from "./types";
import { fromInstalled, fromListing, listCatalog, type WireInstalledApp, type WireListing } from "./wire";

// The owner's shapes (apps lane store.rs, cmux.apps/1): the page adapts to them in one file.
const listing: WireListing = {
  app: "acme.caffeinate",
  name: "Caffeinate",
  summary: "Keeps the Mac awake.",
  publisher: "Acme",
  tier: "verified",
  version: "2.0.1",
  icon: { asset: "assets/icon.png" },
  categories: ["productivity"],
  hide_only: false,
  install: {
    installed: true,
    enabled: false,
    hidden: true,
    sandboxed: false,
    source: "user",
    version: "2.0.0",
    update: null,
  },
};

describe("owner wire shapes", () => {
  test("a listing maps to the page's catalog row", () => {
    expect(fromListing(listing)).toMatchObject({
      id: "acme.caffeinate",
      name: "Caffeinate",
      description: "Keeps the Mac awake.",
      latest_version: "2.0.1",
      installed: true,
      enabled: false,
      hidden: true,
      hide_only: false,
      tier: "verified",
    });
    expect(fromListing({ ...listing, install: null })).toMatchObject({ installed: false });
  });

  test("hide_only from the owner wins over the tier", () => {
    expect(isRemovable(fromListing({ ...listing, hide_only: true }))).toBe(false);
    expect(isRemovable(fromListing({ ...listing, tier: "first-party", hide_only: false }))).toBe(true);
  });

  test("an installed row maps its install state", () => {
    const row: WireInstalledApp = {
      app: "cmux/notes",
      name: "Notes",
      tier: "first-party",
      hide_only: true,
      state: {
        installed: true,
        enabled: true,
        hidden: false,
        sandboxed: true,
        source: "default",
        version: "1.0.0",
        update: null,
      },
      grants: [],
    };
    expect(fromInstalled(row)).toMatchObject({
      id: "cmux/notes",
      version: "1.0.0",
      enabled: true,
      hidden: false,
      sandboxed: true,
      source: "default",
      hide_only: true,
    });
  });

  test("the catalog is read in pages of 200 until next_cursor is null", async () => {
    const pages = [
      { listings: [listing], next_cursor: "c1", revision: 3 },
      { listings: [{ ...listing, app: "b.b" }], next_cursor: null, revision: 3 },
    ];
    const sent: unknown[] = [];
    const client = {
      call: async (_op: string, params: unknown) => {
        sent.push(params);
        return pages.shift();
      },
    };
    const result = await listCatalog(client as never);
    expect(result.apps.map((app) => app.id)).toEqual(["acme.caffeinate", "b.b"]);
    expect(sent).toEqual([{ limit: 200 }, { limit: 200, cursor: "c1" }]);
  });

  test("the store reads the owner's shapes end to end", async () => {
    const provider = new MockAppsProvider();
    const store = new AppsStore(provider);
    store.subscribe(() => undefined);
    await store.start();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const list = provider.calls.find((call) => call.op === AppsOps.catalogList);
    expect(list?.params).toEqual({ limit: 200 });
    expect(store.getSnapshot().catalog.find((app) => app.id === "cmux.github-prs")?.hide_only).toBe(true);
  });
});
