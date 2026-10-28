import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import cliGenerated from "../data/next-docs/cli-reference.generated.json";
import paletteGenerated from "../data/next-docs/palette-reference.generated.json";
import settingsGenerated from "../data/next-docs/settings-reference.generated.json";
import { nextDocHref, nextDocPage, nextDocPages } from "../data/next-docs/pages";
import {
  buildCliReference,
  buildPaletteReference,
  buildSettingsReference,
  formatShortcut,
  mcpToolName,
} from "../scripts/export-next-docs";
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

  test("the settings reference is fresh against the settings schema", () => {
    expect(buildSettingsReference(schema)).toEqual(settingsGenerated as never);
  });

  test("every cmux command written in a hand-written page is a real CLI verb", () => {
    const verbs = new Set(buildCliReference(surfaces).nouns.flatMap((noun) => noun.verbs.map((verb) => verb.command)));
    // Commands of the Rust CLI itself, not app actions (cmux --help).
    const allowed = new Set([
      "cmux action list", "cmux action run", "cmux <noun> <verb>", "cmux mcp serve", "cmux mcp tools",
      "cmux settings set", "cmux version",
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

  test("release docs fall back to Getting Started for a next page", () => {
    expect(docsPathAvailableInChannel("release", "/docs/next/cli")).toBe(false);
    expect(docsPathAvailableInChannel("nightly", "/docs/next/cli")).toBe(true);
    expect(docsChannelUrl("release", "/docs/nightly/next/cli")).toBe("/docs/getting-started");
    expect(docsChannelUrl("nightly", "/docs/next/cli")).toBe("/docs/nightly/next/cli");
  });
});
