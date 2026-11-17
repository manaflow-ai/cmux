import { afterEach, describe, expect, mock, test } from "bun:test";
import { pomodoroListing } from "./fixtures/extension-listings";

mock.module("next/cache", () => ({ cacheLife: () => {} }));
const refs = await import("../app/extensions/_lib/refs");
const registry = await import("../app/extensions/_lib/registry");
const { extensionSitemapEntries } = await import("../app/extensions/_lib/sitemap-entries");

describe("sitemap index pages carry no fixed date", () => {
  test("with no dated listing, the index entries omit lastModified", () => {
    const [extensions, setups] = extensionSitemapEntries(null, null);
    expect(extensions!.lastModified).toBeUndefined();
    expect(setups!.lastModified).toBeUndefined();
  });
});

describe("the listing walk does not drop pages silently", () => {
  const saved = globalThis.fetch;
  const savedError = console.error;
  afterEach(() => {
    globalThis.fetch = saved;
    console.error = savedError;
  });

  /** A registry with `pages` pages of one listing each. */
  function pagedRegistry(pages: number) {
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const cursor = Number(new URL(String(input)).searchParams.get("cursor") ?? "0");
      const item = { ...pomodoroListing, repo: `repo-${cursor}` };
      return Response.json({ items: [item], next: cursor + 1 < pages ? String(cursor + 1) : null });
    }) as unknown as typeof fetch;
  }

  test("walks past the old 50-page bound", async () => {
    pagedRegistry(60);
    const listings = await registry.fetchAllListings("extension");
    expect(listings).toHaveLength(60);
  });

  test("a walk cut at its bound is logged", async () => {
    pagedRegistry(5);
    const logged: string[] = [];
    console.error = (message: string) => void logged.push(message);
    const listings = await registry.fetchAllListings("extension", 3);
    expect(listings).toHaveLength(3);
    expect(logged.join("\n")).toContain("truncated at 3 pages");
  });
});

describe("install references keep @ in a path", () => {
  test("a path segment with @ is kept", () => {
    expect(refs.parseInstallReference("github.com/octo-dev/kit/pkg@2")?.path).toBe("pkg@2");
  });
  test("a trailing @REF on the repo is still dropped", () => {
    expect(refs.parseInstallReference("https://github.com/octo-dev/cmux-pomodoro@v1.2.0")?.repo).toBe("cmux-pomodoro");
    expect(refs.parseInstallReference("github.com/octo-dev/cmux-pomodoro.git@v1")?.repo).toBe("cmux-pomodoro");
  });
});

describe("README images on a host with no raw route", () => {
  test("a relative image on a custom host is dropped, not rendered from null", async () => {
    const { rewriteReadmeUrl } = await import("../app/extensions/_lib/readme");
    const source = { host: "git.example.dev", owner: "octo-dev", repo: "kit", path: "", commit: "0123456789abcdef0123456789abcdef01234567" };
    expect(rewriteReadmeUrl(source, "docs/shot.png?raw=1", "image")).toBeNull();
    expect(rewriteReadmeUrl({ ...source, host: "github.com" }, "docs/shot.png", "image")).toBe(
      "https://raw.githubusercontent.com/octo-dev/kit/0123456789abcdef0123456789abcdef01234567/docs/shot.png",
    );
  });
});
