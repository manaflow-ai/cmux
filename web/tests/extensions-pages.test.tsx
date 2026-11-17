import { afterEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { gitlabListing, pomodoroListing, setupListing, snippetListing, themeListing } from "./fixtures/extension-listings";

// Registry reads are cached with `use cache`; outside Next the cache profile call is a no-op.
mock.module("next/cache", () => ({ cacheLife: () => {} }));

const refs = await import("../app/extensions/_lib/refs");
const { Readme, rewriteReadmeUrl } = await import("../app/extensions/_lib/readme");
const registry = await import("../app/extensions/_lib/registry");
const { listingJsonLd, listingMetadata } = await import("../app/extensions/_lib/seo");
const { extensionSitemapEntries } = await import("../app/extensions/_lib/sitemap-entries");

const pomodoro = registry.parseListing(pomodoroListing)!;
const gitlab = registry.parseListing(gitlabListing)!;
const setup = registry.parseListing(setupListing, "setup")!;
const COMMIT = pomodoro.commit;

describe("listing URLs", () => {
  test("a GitHub repo keeps the short form; other hosts and folders are spelled out", () => {
    expect(refs.listingPath(pomodoro)).toBe("/extensions/octo-dev/cmux-pomodoro");
    expect(refs.listingPath(gitlab)).toBe("/extensions/gitlab.com/nora/cmux-tools/extensions/git-graph");
    expect(refs.listingPath(setup, "setup")).toBe("/setups/octo-dev/my-cmux");
    expect(refs.installPath(pomodoro)).toBe("/extensions/octo-dev/cmux-pomodoro/install");
  });

  test("the catch-all reads the host, owner, repo, folder and page back", () => {
    expect(refs.parseListingSlug(["octo-dev", "cmux-pomodoro"])).toEqual({
      host: "github.com", owner: "octo-dev", repo: "cmux-pomodoro", path: "", page: "listing",
    });
    expect(refs.parseListingSlug(["gitlab.com", "nora", "cmux-tools", "extensions", "git-graph", "install"])).toEqual({
      host: "gitlab.com", owner: "nora", repo: "cmux-tools", path: "extensions/git-graph", page: "install",
    });
    expect(refs.parseListingSlug(["octo-dev", "cmux-pomodoro", "remix"])?.page).toBe("remix");
    for (const bad of [["octo-dev"], ["..", "x"], ["octo-dev", "repo", ".."], ["bad host.com", "a", "b"], ["a", "b%ZZ"]]) {
      expect(refs.parseListingSlug(bad)).toBeNull();
    }
  });

  test("install and remix deeplinks pin the approved commit (contract.md, remix.md)", () => {
    expect(refs.installDeeplink(pomodoro, COMMIT)).toBe(
      `cmux://apps/install?repo=github.com%2Focto-dev%2Fcmux-pomodoro&commit=${COMMIT}`,
    );
    expect(refs.installDeeplink(setup, COMMIT, "setup")).toStartWith("cmux://setups/install?repo=github.com%2Focto-dev%2Fmy-cmux");
    expect(refs.installDeeplink(pomodoro, "main")).not.toContain("commit=");
    expect(refs.remixDeeplink(gitlab, gitlab.commit)).toBe(
      `cmux://build?remix=${encodeURIComponent(`gitlab.com/nora/cmux-tools/extensions/git-graph@${gitlab.commit}`)}`,
    );
  });

  test("the download handoff keeps the reference and reads it back", () => {
    const href = refs.downloadWithInstallHref(gitlab, gitlab.commit);
    const url = new URL(href, "https://cmux.com");
    expect(url.pathname).toBe("/download");
    expect(refs.parseInstallReference(url.searchParams.get("install")!)).toEqual({
      host: "gitlab.com", owner: "nora", repo: "cmux-tools", path: "extensions/git-graph",
    });
    expect(refs.parseInstallReference("https://github.com/octo-dev/cmux-pomodoro@v1.2.0")?.repo).toBe("cmux-pomodoro");
    expect(refs.parseInstallReference("octo-dev/cmux-pomodoro")).toBeNull();
  });

  test("the badge snippet is the contract's exact form", () => {
    expect(refs.badgeSnippet(pomodoro)).toBe(
      "[![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/extensions/octo-dev/cmux-pomodoro)",
    );
  });
});

describe("registry listings", () => {
  test("reads the registry's shapes: publisher object, minCmux, latest release, downloads, tier", () => {
    expect(pomodoro.publisher).toBe("Octo Dev");
    expect(pomodoro.publisherUrl).toBe("https://octo.dev/");
    expect(pomodoro.requiresCmux).toBe("1.4.0");
    expect(pomodoro.latest).toEqual({ version: "1.2.0", tag: "v1.2.0", date: "2026-11-14T12:00:00Z" });
    expect(pomodoro.downloads).toBe(4120);
    expect(pomodoro.tier).toBe("plugin");
    expect(registry.parseListing(themeListing)!.tier).toBe("theme");
    expect(registry.parseListing(snippetListing)!.tier).toBe("snippet");
    expect(setup.tier).toBe("setup");
    expect(registry.parseListing({ ...gitlabListing, installs: 3 })!.downloads).toBe(3);
  });

  test("drops what a page cannot use: a bad commit, non-https media", () => {
    expect(registry.parseListing({ ...pomodoroListing, commit: "main" })).toBeNull();
    const listing = registry.parseListing({ ...pomodoroListing, iconUrl: "http://x.test/i.png", screenshots: ["javascript:alert(1)", "https://x.test/s.png"] })!;
    expect(listing.iconUrl).toBeUndefined();
    expect(listing.screenshots).toEqual(["https://x.test/s.png"]);
  });

  test("a setup's summary becomes rows of what it installs", () => {
    const rows = registry.parseListing(
      { ...setupListing, contents: undefined, changes: { files: ["keybindings.json", "themes/night.json"], settings: ["appearance.themeFile"], actions: ["hello"] }, extensions: ["github.com/a/b@v1"] },
      "setup",
    )!.contents;
    expect(rows.map((row) => row.kind)).toEqual(["keymap", "theme", "setting", "action", "extension"]);
    expect(rows.at(-1)).toEqual({ kind: "extension", name: "b", ref: "github.com/a/b@v1" });
  });

  test("a root GitHub listing uses /OWNER/REPO; any other uses by-ref", () => {
    expect(registry.registryListingPath(pomodoro)).toBe("/octo-dev/cmux-pomodoro");
    expect(registry.registryListingPath(gitlab)).toBe("/by-ref?ref=gitlab.com%2Fnora%2Fcmux-tools%2Fextensions%2Fgit-graph");
  });

  test("the registry URL comes from CMUX_REGISTRY_URL, else production", () => {
    expect(registry.registryBaseUrl({ CMUX_REGISTRY_URL: "http://127.0.0.1:8787/" })).toBe("http://127.0.0.1:8787");
    expect(registry.registryBaseUrl({})).toBe(registry.DEFAULT_REGISTRY_URL);
  });

  describe("an unreachable registry degrades", () => {
    const saved = globalThis.fetch;
    afterEach(() => {
      globalThis.fetch = saved;
    });

    test("the index reads null and a page reads no listing", async () => {
      globalThis.fetch = (async () => {
        throw new Error("offline");
      }) as unknown as typeof fetch;
      expect(await registry.loadAllListings("extension")).toBeNull();
      expect(await registry.loadListing("extension", pomodoro)).toBeNull();
    });

    test("a 404 is no listing, and an author page only shows the author's own", async () => {
      globalThis.fetch = (async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/v1/authors/")) return Response.json({ items: [pomodoroListing, themeListing] });
        return Response.json({ error: "extension.not_found" }, { status: 404 });
      }) as typeof fetch;
      expect(await registry.loadListing("extension", pomodoro)).toBeNull();
      expect((await registry.loadAuthorListings("octo-dev"))!.map((l) => l.name)).toEqual(["Pomodoro"]);
    });
  });
});

describe("README rendering", () => {
  const source = { ...pomodoro };
  const folder = { ...gitlab };

  test("relative links and images point at the repo at the approved commit", () => {
    expect(rewriteReadmeUrl(source, "docs/hero.png", "image")).toBe(
      `https://raw.githubusercontent.com/octo-dev/cmux-pomodoro/${COMMIT}/docs/hero.png`,
    );
    expect(rewriteReadmeUrl(source, "./docs/settings.md#minutes", "link")).toBe(
      `https://github.com/octo-dev/cmux-pomodoro/blob/${COMMIT}/docs/settings.md#minutes`,
    );
    expect(rewriteReadmeUrl(source, "examples/", "link")).toBe(`https://github.com/octo-dev/cmux-pomodoro/tree/${COMMIT}/examples`);
    // A folder listing resolves against its folder; a leading slash against the repo root.
    expect(rewriteReadmeUrl(folder, "graph.png", "image")).toBe(
      `https://gitlab.com/nora/cmux-tools/-/raw/${folder.commit}/extensions/git-graph/graph.png`,
    );
    expect(rewriteReadmeUrl(folder, "/LICENSE", "link")).toBe(`https://gitlab.com/nora/cmux-tools/-/blob/${folder.commit}/LICENSE`);
    expect(rewriteReadmeUrl(folder, "../../README.md", "link")).toBe(`https://gitlab.com/nora/cmux-tools/-/blob/${folder.commit}/README.md`);
  });

  test("unsafe and escaping URLs are dropped; absolute https and anchors stay", () => {
    expect(rewriteReadmeUrl(source, "javascript:alert(1)", "link")).toBeNull();
    expect(rewriteReadmeUrl(source, "data:image/png;base64,AAAA", "image")).toBeNull();
    expect(rewriteReadmeUrl(source, "http://insecure.test/x.png", "image")).toBeNull();
    expect(rewriteReadmeUrl(source, "../../etc/passwd", "link")).toBeNull();
    expect(rewriteReadmeUrl(source, "https://example.com/a", "link")).toBe("https://example.com/a");
    expect(rewriteReadmeUrl(source, "#install", "link")).toBe("#install");
  });

  test("raw HTML is sanitized and links are marked outbound", () => {
    const html = renderToStaticMarkup(<Readme source={source} markdown={pomodoro.readme} />);
    expect(html).not.toContain("<script");
    expect(html).not.toContain("javascript:");
    expect(html).toContain(`src="https://raw.githubusercontent.com/octo-dev/cmux-pomodoro/${COMMIT}/docs/hero.png"`);
    expect(html).toContain('rel="nofollow ugc noopener noreferrer"');
    expect(html).toContain("<table>");
    const evil = renderToStaticMarkup(
      <Readme source={source} markdown={'<img src="x.png" onerror="alert(1)"><iframe src="https://e.test"></iframe><a href="x" style="color:red">s</a>'} />,
    );
    expect(evil).not.toMatch(/onerror|<iframe|style=/);
  });
});

describe("structured data and metadata", () => {
  test("a listing page is a free macOS SoftwareApplication linking its source", () => {
    const data = listingJsonLd(pomodoro);
    expect(data).toMatchObject({
      "@context": "https://schema.org",
      "@type": "SoftwareApplication",
      name: "Pomodoro",
      url: "https://cmux.com/extensions/octo-dev/cmux-pomodoro",
      applicationCategory: "DeveloperApplication",
      operatingSystem: "macOS",
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      codeRepository: `https://github.com/octo-dev/cmux-pomodoro/tree/${COMMIT}`,
      sameAs: ["https://github.com/octo-dev/cmux-pomodoro"],
      softwareVersion: "1.2.0",
      softwareRequirements: "cmux 1.4.0 or later",
      license: "MIT",
    });
    expect(JSON.stringify(data)).not.toContain("undefined");
  });

  test("metadata: canonical English URL, generated social image", () => {
    const metadata = listingMetadata(pomodoro);
    expect(metadata.alternates?.canonical).toBe("https://cmux.com/extensions/octo-dev/cmux-pomodoro");
    expect(JSON.stringify(metadata.openGraph)).toContain(
      "https://cmux.com/extensions/og.png?kind=extension&page=%2Fextensions%2Focto-dev%2Fcmux-pomodoro",
    );
    expect(String(metadata.description).length).toBeLessThanOrEqual(300);
  });
});

describe("sitemap", () => {
  test("lists the index pages, every listing page and every author once", () => {
    const urls = extensionSitemapEntries([pomodoro, gitlab, registry.parseListing(themeListing)!], [setup]).map((entry) => entry.url);
    expect(urls).toEqual([
      "https://cmux.com/extensions",
      "https://cmux.com/setups",
      "https://cmux.com/extensions/octo-dev/cmux-pomodoro",
      "https://cmux.com/extensions/gitlab.com/nora/cmux-tools/extensions/git-graph",
      "https://cmux.com/extensions/nora/midnight-theme",
      "https://cmux.com/setups/octo-dev/my-cmux",
      "https://cmux.com/u/octo-dev",
      "https://cmux.com/u/nora",
    ]);
  });

  test("an unreachable registry still lists the index pages", () => {
    expect(extensionSitemapEntries(null, null).map((entry) => entry.url)).toEqual([
      "https://cmux.com/extensions",
      "https://cmux.com/setups",
    ]);
  });
});
