// Every chat page bench/first-load-after-restart.bench.ts opens gets the bench's host (`prepare`) before it
// navigates to the chat. Since the bundle loads main as the app does (#60624), the dev host is the init script's
// only: a page without it never opens its socket to the stand-in acpmux. The reopen modes' warm page was opened
// without it, drew the composer alone and waited out its 120 s, so open_recent and restart in the settled-page
// bench (bench/settled-page.bench.ts) hung on every run. This scan is the detector for that class: a page that
// goes to the chat (`url`, `spareUrl`) with no `prepare(page` between its `newPage()` and its `goto` fails here.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const BENCH = path.resolve(import.meta.dir, "../bench/first-load-after-restart.bench.ts");

/// The pages in `source` that go to the chat without `prepare` since they were opened, as `name@line` (pure).
export function unhostedChatPages(source: string): string[] {
  const found: string[] = [];
  const line = (at: number) => source.slice(0, at).split("\n").length;
  for (const go of source.matchAll(/\b(\w+)\.goto\(\s*(url|spareUrl)\b/g)) {
    const at = go.index ?? 0;
    const opened = source.lastIndexOf("newPage()", at);
    const between = opened < 0 ? source.slice(0, at) : source.slice(opened, at);
    if (!new RegExp(`\\bprepare\\(\\s*${go[1]}\\b`).test(between)) found.push(`${go[1]}@${line(at)}`);
  }
  return found;
}

describe("first-load bench chat pages", () => {
  test("every page that goes to the chat has the bench's host", () => {
    const source = fs.readFileSync(BENCH, "utf8");
    expect(source.match(/\.goto\(\s*(url|spareUrl)\b/g)?.length ?? 0).toBeGreaterThanOrEqual(3);
    expect(unhostedChatPages(source)).toEqual([]);
  });

  test("names the warm page as it was before the fix", () => {
    const before = [
      "  if (MODES.some(isReopen)) {",
      "    warmContext = await browser.newContext({ viewport: VIEWPORT });",
      "    const other = await warmContext.newPage();",
      "    await other.goto(url);",
      "  }",
      "  const prepare = async (page: Page) => {};",
      "  const warm = async () => {",
      "    const page = await context.newPage();",
      "    await prepare(page, null, 120_000);",
      "    await page.goto(url);",
      "  };",
    ].join("\n");
    expect(unhostedChatPages(before)).toEqual(["other@4"]);
  });

  test("a page prepared in a loop over the pages it opened passes", () => {
    const loop = [
      "const pages = await Promise.all(Array.from({ length: PAGES }, () => context.newPage()));",
      "for (const one of pages) {",
      "  await prepare(",
      "    one,",
      "    null,",
      "  );",
      "}",
      "await Promise.all(pages.map((one) => one.goto(url, { waitUntil: 'commit' })));",
    ].join("\n");
    expect(unhostedChatPages(loop)).toEqual([]);
  });
});
