import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import cliGenerated from "../data/next-docs/cli-reference.generated.json";
import paletteGenerated from "../data/next-docs/palette-reference.generated.json";
import settingsGenerated from "../data/next-docs/settings-reference.generated.json";
import { nextDocHref, nextDocPage, nextDocPages, nextDocPublicPath, repoSourceHref } from "../data/next-docs/pages";
import { buildLlmsText, resolveAgentPageVariant } from "../app/lib/agent-page-paths";
import { sitemapEntries } from "../app/sitemap";
import {
  buildCliReference,
  buildPaletteReference,
  buildSettingsReference,
  formatShortcut,
  mcpToolName,
} from "../scripts/export-next-docs";
import { docsChannelUrl, docsPathAvailableInChannel } from "../app/lib/docs-channel";
import {
  docsContentLang,
  docsContentLangAttributes,
  flatNavItems,
  navItemsForLocale,
} from "../app/[locale]/components/docs-nav-items";

// The cmux-next docs reference pages are generated from the action catalog and
// the settings schema (plans/cmux-next/docs-DESIGN.md). web/ never reads those
// at build time, so these tests read them and require the copies to match.

const repo = fileURLToPath(new URL("../..", import.meta.url));
const surfaces = JSON.parse(readFileSync(join(repo, "plans/cmux-next/action-surfaces.json"), "utf8"));
const schema = JSON.parse(readFileSync(join(repo, "schemas/settings/settings-schema.json"), "utf8"));

describe("cmux-next docs", () => {
  test("the CLI and MCP reference is fresh against the action catalog", () => {
    expect(buildCliReference(surfaces)).toEqual(cliGenerated as never);
  });

  test("the command palette and shortcuts reference is fresh against the action catalog", () => {
    expect(buildPaletteReference(surfaces)).toEqual(paletteGenerated as never);
  });

  test("MCP tool names follow the server's rule", () => {
    // cmux-tui/crates/cmux-tui/src/cli/mcp/action_tools.rs `tool_name` and its tests.
    expect(mcpToolName("workspace rename")).toBe("app_workspace_rename");
    expect(mcpToolName("app new-window")).toBe("app_new_window");
    expect(mcpToolName("space select-1-9")).toBe("app_space_select_1_9");
    expect(mcpToolName("app")).toBeNull();
    expect(mcpToolName("tab bad!name")).toBeNull();
    const reference = buildCliReference(surfaces);
    const names = reference.nouns.flatMap((noun) => noun.verbs.flatMap((verb) => (verb.mcpTool ? [verb.mcpTool] : [])));
    expect(new Set(names).size).toBe(names.length);
    expect(names.length).toBe(reference.counts.mcp);
  });

  test("shortcuts read the way the app's menus write them", () => {
    expect(formatShortcut({ key: "p", modifiers: ["cmd", "shift"] })).toBe("⇧⌘P");
    expect(formatShortcut({ key: "1", modifiers: ["opt", "ctrl"], family: "digits" })).toBe("⌃⌥1…9");
    const palette = buildPaletteReference(surfaces).sections.flatMap((section) => section.entries);
    expect(palette.find((entry) => entry.id === "commandPalette")?.shortcut).toBe("⇧⌘P");
  });

  test("every link between cmux-next pages names a real page", () => {
    const broken = nextDocPages.flatMap((page) => (page.links ?? []).filter((slug) => !nextDocPage(slug)).map((slug) => `${page.slug} -> ${slug}`));
    expect(broken).toEqual([]);
    expect(nextDocHref("getting-started")).toBe("/docs/next");
  });

  // The architecture page points at folders and files; a move or rename must not leave it
  // linking to nothing, and a file links under blob, a folder under tree.
  test("every repository path a page links to exists and is the kind it says", () => {
    const wrong = nextDocPages.flatMap((page) =>
      page.body.flatMap((block) => ("files" in block ? block.files : []))
        .filter((file) => {
          const full = join(repo, file.path);
          return !existsSync(full) || statSync(full).isDirectory() !== (file.kind === "folder");
        })
        .map((file) => `${page.slug}: ${file.path} (${file.kind})`));
    expect(wrong).toEqual([]);
    expect(repoSourceHref("cmux-tui/docs", "folder")).toBe("https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/docs");
    expect(repoSourceHref("cmux-tui/spec/resource-api-v2.md", "file")).toBe("https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/cmux-tui/spec/resource-api-v2.md");
  });

  test("the settings reference is fresh against the settings schema", () => {
    expect(buildSettingsReference(schema)).toEqual(settingsGenerated as never);
  });

  // docs/configuration.md is written by hand, while the settings schema is the
  // app's own source of truth. #23844 widened cmux Classic Mode to Cmd-N, the
  // sidebar's + and new windows and updated the schema's help, but not the page,
  // which then told people a new workspace still starts on the New Tab page.
  test("every shortcut a setting's schema help names is in its hand-written section", () => {
    const configuration = readFileSync(join(repo, "docs/configuration.md"), "utf8");
    const headings = [...configuration.matchAll(/^## `([^`]+)`$/gm)];
    const sections = new Map(headings.map((heading, index) => [
      heading[1],
      configuration.slice(heading.index + heading[0].length, headings[index + 1]?.index ?? configuration.length),
    ]));
    expect(sections.size).toBe(headings.length);
    const shortcut = /Cmd-(?:Shift-|Opt-|Ctrl-)*[A-Z0-9]/g;
    const missing: string[] = [];
    for (const section of settingsGenerated.sections) {
      for (const row of section.rows) {
        const written = sections.get(row.key);
        if (!written) continue; // a setting the page does not cover at all
        // The page writes Cmd+T where the schema writes Cmd-T; both read the same.
        const has = new Set(written.replaceAll("Cmd+", "Cmd-").match(shortcut));
        for (const key of new Set(row.help.match(shortcut))) {
          if (!has.has(key)) missing.push(`${row.key}: ${key}`);
        }
      }
    }
    expect(missing).toEqual([]);
  });

  test("every cmux command written in a hand-written page is a real CLI verb", () => {
    const verbs = new Set(buildCliReference(surfaces).nouns.flatMap((noun) => noun.verbs.map((verb) => verb.command)));
    // Commands of the Rust CLI itself, not app actions (cmux --help). `cmux harness` and
    // `cmux acp` are acpmux's CLI (cmux-tui/crates/acpmux/src/cli/harness.rs, ledger.rs,
    // host_enroll.rs); `cloud secret` and `machine vault` are cmux-tui's
    // (src/cli/cloud_secret.rs, src/cli/machine_join/vault.rs).
    const allowed = new Set([
      "cmux action list", "cmux action run", "cmux <noun> <verb>", "cmux mcp serve", "cmux mcp tools",
      "cmux settings set", "cmux version", "cmux harness add", "cmux harness secret", "cmux harness doctor",
      "cmux acp ledger", "cmux acp machine", "cmux cloud secret", "cmux machine vault",
    ]);
    const unknown: string[] = [];
    for (const page of nextDocPages) {
      for (const block of page.body) {
        if (!("code" in block)) continue;
        for (const line of block.code.split("\n")) {
          const match = /^(cmux [a-z<>-]+(?: [a-z<>-]+)?)/.exec(line.trim());
          if (match && !verbs.has(match[1]) && !allowed.has(match[1])) unknown.push(`${page.slug}: ${match[1]}`);
        }
      }
    }
    expect(unknown).toEqual([]);
  });

  test("the sidebar lists every page once, in nightly only", () => {
    const hrefs = (channel: "release" | "nightly") =>
      flatNavItems(navItemsForLocale("en", channel)).map((item) => item.href).filter((href) => href.startsWith("/docs/next"));
    const expected = nextDocPages.map((page) => nextDocHref(page.slug));
    expect(hrefs("nightly").sort()).toEqual(expected.sort());
    expect(hrefs("release")).toEqual([]);
    expect(flatNavItems(navItemsForLocale("ja", "nightly")).some((item) => item.href.startsWith("/docs/next"))).toBe(false);
  });

  // The pages were in neither the sitemap nor llms.txt, so search and answer engines
  // never found them.
  test("the sitemap and llms.txt list every page at its nightly URL", () => {
    const urls = sitemapEntries().map((entry) => entry.url);
    const llms = buildLlmsText("https://cmux.com");
    for (const page of nextDocPages) {
      const path = nextDocPublicPath(page.slug);
      expect(urls).toContain(`https://cmux.com${path}`);
      expect(urls).not.toContain(`https://cmux.com/ja${path}`);
      expect(llms).toContain(`https://cmux.com${path}.md`);
    }
    expect(nextDocPublicPath("getting-started")).toBe("/docs/nightly/next");
    expect(nextDocPublicPath("own-keys")).toBe("/docs/nightly/next/own-keys");
  });

  test("Markdown variants resolve on cmux.com and in the nightly zone", () => {
    // The nightly zone gets the path without /nightly (next.config.ts rewrites).
    for (const path of ["/docs/nightly/next/own-keys.md", "/docs/next/own-keys.md", "/docs/next.txt"]) {
      expect(resolveAgentPageVariant(path)).not.toBeNull();
    }
    expect(resolveAgentPageVariant("/docs/next/no-such-page.md")).toBeNull();
  });

  // The pages are English only. A NEXT_LOCALE=ja cookie or Accept-Language: ja sent a reader to
  // /ja/docs/next/..., which the route answered with 404.
  test("every locale serves the English page, with the English URL as canonical", async () => {
    const saved = process.env.CMUX_DOCS_CHANNEL;
    process.env.CMUX_DOCS_CHANNEL = "nightly";
    try {
      const slugRoute = await import("../app/[locale]/(landing)/docs/next/[slug]/page");
      const indexRoute = await import("../app/[locale]/(landing)/docs/next/page");
      for (const locale of ["ja", "de", "en"]) {
        const params = Promise.resolve({ locale, slug: "own-keys" });
        const element = await slugRoute.default({ params });
        expect(element.props.page.slug).toBe("own-keys");
        const metadata = await slugRoute.generateMetadata({ params: Promise.resolve({ locale, slug: "own-keys" }) });
        expect(metadata.alternates.canonical).toBe("https://cmux.com/docs/nightly/next/own-keys");
        expect(indexRoute.default().props.page.slug).toBe("getting-started");
        const index = await indexRoute.generateMetadata({ params: Promise.resolve({ locale }) });
        expect(index.alternates.canonical).toBe("https://cmux.com/docs/nightly/next");
      }
      await expect(slugRoute.default({ params: Promise.resolve({ locale: "ja", slug: "no-such-page" }) })).rejects.toThrow();
    } finally {
      if (saved === undefined) delete process.env.CMUX_DOCS_CHANNEL;
      else process.env.CMUX_DOCS_CHANNEL = saved;
    }
  });

  // A lang="en" wrapper around the page put an element between .docs-content and the page's
  // h1 and p, which globals.css styles as its direct children (`.docs-content > p`,
  // `.docs-content > h1 + p`, `.docs-content > h1:first-of-type`).
  test("a page's blocks are direct children of .docs-content, which carries its language", async () => {
    const { NextDocView } = await import("../app/[locale]/(landing)/docs/next/next-doc-view");
    const { DocsHeading } = await import("../app/[locale]/components/docs-heading");
    const { Fragment } = await import("react");
    const page = nextDocPage("own-keys")!;
    const tree = NextDocView({ page }) as { type: unknown; props: { children: unknown[] } };
    expect(tree.type).toBe(Fragment);
    const children = tree.props.children.flat().filter(Boolean) as { type: unknown }[];
    const headingAt = children.findIndex((child) => child.type === DocsHeading);
    expect(headingAt).toBeGreaterThanOrEqual(0);
    expect(children[headingAt + 1]?.type).toBe("p");
    // One child per body block (each renders one h2, p, ul, code block or callout), none wrapped.
    expect(children.length).toBeGreaterThanOrEqual(page.body.length + 3);
    expect(children.some((child) => child.type === "div" || child.type === "section")).toBe(false);

    for (const path of ["/docs/next", "/docs/next/own-keys", "/docs/base"]) {
      expect(docsContentLang(path, "ja")).toBe("en");
      expect(docsContentLang(path, "en")).toBe("en");
    }
    expect(docsContentLang("/docs/getting-started", "ja")).toBe("ja");
    const layout = readFileSync(join(repo, "web/app/[locale]/(landing)/docs/docs-nav.tsx"), "utf8");
    expect(layout).toMatch(/className="docs-content[^"]*"\s+\{\.\.\.docsContentLangAttributes\(contentLang, locale\)\}/);
  });

  // Under Arabic the root is dir="rtl" and lang="en" does not change direction, so the English
  // body of a cmux-next page laid out its text and tables right to left.
  test("an English body under a right-to-left locale is marked left to right", () => {
    const attributes = (path: string, locale: string) =>
      docsContentLangAttributes(docsContentLang(path, locale), locale);
    expect(attributes("/docs/next/own-keys", "ar")).toEqual({ lang: "en", dir: "ltr" });
    expect(attributes("/docs/base", "ar")).toEqual({ lang: "en", dir: "ltr" });
    expect(attributes("/docs/next/own-keys", "ja")).toEqual({ lang: "en" });
    expect(attributes("/docs/next/own-keys", "en")).toEqual({});
    expect(attributes("/docs/getting-started", "ar")).toEqual({});
  });

  test("release docs fall back to Getting Started for a next page", () => {
    expect(docsPathAvailableInChannel("release", "/docs/next/cli")).toBe(false);
    expect(docsPathAvailableInChannel("nightly", "/docs/next/cli")).toBe(true);
    expect(docsChannelUrl("release", "/docs/nightly/next/cli")).toBe("/docs/getting-started");
    expect(docsChannelUrl("nightly", "/docs/next/cli")).toBe("/docs/nightly/next/cli");
  });
});
