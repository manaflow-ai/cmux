import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import cliGenerated from "../data/next-docs/cli-reference.generated.json";
import settingsGenerated from "../data/next-docs/settings-reference.generated.json";
import { nextDocPages } from "../data/next-docs/pages";
import { buildCliReference, buildSettingsReference } from "../scripts/export-next-docs";
import { docsChannelUrl, docsPathAvailableInChannel } from "../app/lib/docs-channel";
import { flatNavItems, navItemsForLocale } from "../app/[locale]/components/docs-nav-items";

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

  test("the settings reference is fresh against the settings schema", () => {
    expect(buildSettingsReference(schema)).toEqual(settingsGenerated as never);
  });

  test("every cmux command written in a hand-written page is a real CLI verb", () => {
    const verbs = new Set(buildCliReference(surfaces).nouns.flatMap((noun) => noun.verbs.map((verb) => verb.command)));
    const allowed = new Set(["cmux action list", "cmux action run", "cmux <noun> <verb>", "cmux mcp serve", "cmux version"]);
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
    const expected = nextDocPages.map((page) => (page.slug === "getting-started" ? "/docs/next" : `/docs/next/${page.slug}`));
    expect(hrefs("nightly").sort()).toEqual(expected.sort());
    expect(hrefs("release")).toEqual([]);
    expect(flatNavItems(navItemsForLocale("ja", "nightly")).some((item) => item.href.startsWith("/docs/next"))).toBe(false);
  });

  test("release docs fall back to Getting Started for a next page", () => {
    expect(docsPathAvailableInChannel("release", "/docs/next/cli")).toBe(false);
    expect(docsPathAvailableInChannel("nightly", "/docs/next/cli")).toBe(true);
    expect(docsChannelUrl("release", "/docs/nightly/next/cli")).toBe("/docs/getting-started");
    expect(docsChannelUrl("nightly", "/docs/next/cli")).toBe("/docs/nightly/next/cli");
  });
});
