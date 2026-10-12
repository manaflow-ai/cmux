// A setting row says what it is in one short line, or nothing (Leo, 2026-10-11): the line under a
// row's title is the descriptor's `summary`, never the long `help` the docs and the MDM manifest
// keep. The lint below fails a summary over 60 characters in English or 80 in another language,
// and any row line the page draws over 60 characters.
import { afterAll, afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { categories } from "./categories";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, rowElement } = await import("./testing");

const EN_LIMIT = 60;
const LOCALE_LIMIT = 80;
const here = path.dirname(new URL(import.meta.url).pathname);
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

/** The line under each schema row's title, as the page draws it. */
function rowLines(container: ParentNode): Array<{ row: string; line: string }> {
  return [...container.querySelectorAll<HTMLElement>("[data-row-key], [data-theme-row='app']")].flatMap((row) => {
    const line = row.querySelector<HTMLElement>(":scope > .row-main > .row-label > .row-help");
    const key = row.dataset.rowKey ?? "appearance.appTheme";
    return line ? [{ row: key, line: line.textContent ?? "" }] : [];
  });
}

test("Backdrop Art says what it is in one short line, with no hover title", async () => {
  page = await renderPage({ path: "/settings/appearance" });
  const line = rowElement(page.container, "appearance.backdropArt").querySelector<HTMLElement>(".row-help");
  expect(line?.textContent).toBe("Painting behind the window");
  expect(line?.hasAttribute("title")).toBe(false);
});

test("no row line on any Settings page is over 60 characters", async () => {
  const long: string[] = [];
  for (const category of categories) {
    page = await renderPage({
      path: `/settings/${category.id}`,
      mock: { values: { "appearance.experimentalControls": true } },
    });
    for (const { row, line } of rowLines(page.container)) {
      if (characters(line) > EN_LIMIT) long.push(`${row} (${characters(line)}): ${line}`);
    }
    page.unmount();
    page = null;
  }
  expect(long).toEqual([]);
});

test("every settings summary in the catalog fits: 60 characters in English, 80 in other languages", () => {
  const catalog = JSON.parse(readFileSync(catalogFile, "utf8")) as {
    strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }>;
  };
  const long: string[] = [];
  for (const [key, entry] of Object.entries(catalog.strings)) {
    if (!/^settings\..+\.summary$/.test(key)) continue;
    for (const [locale, localization] of Object.entries(entry.localizations ?? {})) {
      const value = localization.stringUnit?.value ?? "";
      const limit = locale === "en" ? EN_LIMIT : LOCALE_LIMIT;
      const length = characters(value);
      if (length > limit) long.push(`${key} ${locale} (${length}): ${value}`);
    }
  }
  expect(long).toEqual([]);
});
