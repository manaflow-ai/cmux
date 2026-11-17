import { afterEach, describe, expect, mock, test } from "bun:test";
import { gitlabListing, pomodoroListing, setupListing } from "./fixtures/extension-listings";

mock.module("next/cache", () => ({ cacheLife: () => {} }));
const registry = await import("../app/extensions/_lib/registry");
const { rewriteReadmeUrl } = await import("../app/extensions/_lib/readme");
const { loadIndexListings } = await import("../app/[locale]/(landing)/extensions/listing-index");

const pomodoro = registry.parseListing(pomodoroListing)!;
const COMMIT = pomodoro.commit;
const saved = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = saved;
});

describe("README relative URLs keep their query and are encoded once", () => {
  test("an encoded space stays one encoded space", () => {
    expect(rewriteReadmeUrl(pomodoro, "assets/screen%20shot.png", "image")).toBe(
      `https://raw.githubusercontent.com/octo-dev/cmux-pomodoro/${COMMIT}/assets/screen%20shot.png`,
    );
    expect(rewriteReadmeUrl(pomodoro, "docs/my%20notes.md", "link")).toBe(
      `https://github.com/octo-dev/cmux-pomodoro/blob/${COMMIT}/docs/my%20notes.md`,
    );
  });

  test("a query string is kept, before the fragment", () => {
    expect(rewriteReadmeUrl(pomodoro, "docs/a.md?plain=1#usage", "link")).toBe(
      `https://github.com/octo-dev/cmux-pomodoro/blob/${COMMIT}/docs/a.md?plain=1#usage`,
    );
    expect(rewriteReadmeUrl(pomodoro, "shot.svg?sanitize=true", "image")).toBe(
      `https://raw.githubusercontent.com/octo-dev/cmux-pomodoro/${COMMIT}/shot.svg?sanitize=true`,
    );
  });

  test("an encoded climb out of the repo is still dropped", () => {
    expect(rewriteReadmeUrl(pomodoro, "%2e%2e/%2e%2e/etc/passwd", "link")).toBeNull();
    expect(rewriteReadmeUrl(pomodoro, "a%2F..%2F..%2Fx", "link")).toBeNull();
  });
});

describe("author lookups keep the listing's host", () => {
  test("More by for a GitLab owner asks the registry for that host and keeps only that host", async () => {
    const asked: string[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      asked.push(String(input));
      return Response.json({ items: [gitlabListing, { ...pomodoroListing, owner: "nora" }] });
    }) as unknown as typeof fetch;
    const listings = await registry.loadAuthorListings("nora", "gitlab.com");
    expect(asked[0]).toContain("host=gitlab.com");
    expect(listings!.map((listing) => listing.host)).toEqual(["gitlab.com"]);
  });
});

describe("registry outages and Next's own signals", () => {
  test("/setups reads unavailable, not empty, when the registry is down", async () => {
    globalThis.fetch = (async () => {
      throw new Error("offline");
    }) as unknown as typeof fetch;
    expect(await loadIndexListings("setup")).toBeNull();
  });

  test("a prerender that ended is rethrown, not rendered as an outage", async () => {
    const ended = Object.assign(new Error("During prerendering, dynamic use cache rejects"), { digest: "HANGING_PROMISE_REJECTION" });
    globalThis.fetch = (async () => {
      throw ended;
    }) as unknown as typeof fetch;
    await expect(registry.loadAllListings("setup")).rejects.toBe(ended);
    await expect(registry.loadListing("setup", registry.parseListing(setupListing, "setup")!)).rejects.toBe(ended);
    await expect(registry.loadAuthorListings("octo-dev")).rejects.toBe(ended);
  });
});
