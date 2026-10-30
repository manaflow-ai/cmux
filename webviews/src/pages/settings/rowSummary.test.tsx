// A setting row says what it is in one short line, or nothing (Leo, 2026-10-11): the line under a
// row's title is the descriptor's `summary`, never the long `help` the docs and the MDM manifest
// keep. The lint below fails any description line the page draws (a row's line, a card's intro, a
// status line) over 60 characters in any language, and any schema summary over 60 characters.
// Its sweep renders every Settings page in all 21 locales (a 300 s test limit), past the 120 s
// file default on a busy worker:
// cmux-web-test-timeout: 360
import { afterAll, afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { LOCALES } from "../../../scripts/pages/gen-strings.mjs";
import { categories } from "./categories";
import type { ComputerUsePhase } from "./ops";
import { schema } from "./schema";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, rowElement } = await import("./testing");

const LIMIT = 60;
const here = import.meta.dir;
const catalogFile = path.resolve(
  here,
  "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings",
);

/** Characters as a reader counts them (Thai and Khmer marks join the letter they sit on). */
const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const characters = (value: string) => [...segmenter.segment(value)].length;

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

/**
 * Every description line the page draws: a row's line under its title, a card's intro, a status
 * line. `.selectable` lines show a value (a file path, a config file), not a description.
 */
function descriptionLines(container: ParentNode): string[] {
  return [...container.querySelectorAll<HTMLElement>(".row-help:not(.selectable), [data-intro]")].map(
    (line) => line.textContent?.trim() ?? "",
  );
}

const phases: ComputerUsePhase[] = ["off", "unavailable", "starting", "ready", "version_mismatch"];

type View = {
  name: string;
  path: string;
  values?: Record<string, unknown>;
  phase?: ComputerUsePhase;
  helper?: string | null;
};

/** The pages and states that draw description lines: every category, plus the theme studio's
 * light and dark rows and every Computer Use phase, with and without a signed helper. */
const views: View[] = [
  ...categories.map((category) => ({ name: category.id, path: `/settings/${category.id}` })),
  {
    name: "theme light/dark",
    path: "/settings/theme",
    values: { "appearance.theme": "light:GitHub Light,dark:Dracula" },
  },
  ...phases.flatMap((phase) =>
    [null, "cmux Computer Use"].map((helper) => ({
      name: `computer use ${phase} ${helper ?? "unsigned"}`,
      path: "/settings/agents",
      phase,
      helper,
    })),
  ),
];

test("Material says what Clear Glass does in one short line, with no tooltip repeating it", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  const line = rowElement(page.container, "appearance.backgroundBlur").querySelector<HTMLElement>(".row-help");
  expect(line?.textContent).toBe("Clear Glass shows the desktop through the wallpaper");
  expect(line?.title).toBe("");
});

test("no description line on any Settings page is over 60 characters, in any language", async () => {
  const long = new Set<string>();
  for (const locale of LOCALES as string[]) {
    for (const view of views) {
      page = await renderPage({
        path: view.path,
        locale,
        mock: { values: { "appearance.experimentalControls": true, ...view.values } },
        setup: (provider) => {
          if (!view.phase) return;
          provider.host = {
            ...provider.host,
            computer_use: {
              phase: view.phase,
              accessibility: true,
              screen_recording: false,
              helper: view.helper ?? null,
            },
          };
        },
      });
      for (const line of descriptionLines(page.container)) {
        if (characters(line) > LIMIT) long.add(`${locale} ${view.name} (${characters(line)}): ${line}`);
      }
      page.unmount();
      page = null;
    }
  }
  expect([...long]).toEqual([]);
}, 300_000);

test("every schema summary fits 60 characters in every language", () => {
  const catalog = JSON.parse(readFileSync(catalogFile, "utf8")) as {
    strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }>;
  };
  const keys = schema.rows.flatMap((row) => (row.summary?.key ? [row.summary.key] : []));
  expect(keys.length).toBeGreaterThan(0);
  const long: string[] = [];
  for (const key of keys) {
    const localizations = catalog.strings[key]?.localizations ?? {};
    for (const locale of LOCALES as string[]) {
      const value = localizations[locale]?.stringUnit?.value;
      if (value === undefined) long.push(`${key} ${locale}: missing`);
      else if (characters(value) > LIMIT) long.push(`${key} ${locale} (${characters(value)}): ${value}`);
    }
  }
  expect(long).toEqual([]);
});
