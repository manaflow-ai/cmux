// l10n-allow-file: public sample paths and labels, not shipped UI.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium } from "playwright";
import { PathChip, ElsewhereChip, UrlChip } from "../src/agent-session/acpmux/chips/LinkChips";
import { resetLinkStore, seedLinkStore } from "../src/agent-session/acpmux/chips/linkStore";
import { requireBrowserLane } from "./support/requireBrowserLane";
import strings from "../src/agent-session/acpmux/generated/strings.json";

await requireBrowserLane("inline-reference-chips.test.tsx", async () => {
  globalThis.__cmuxPaneStrings = strings;
  const browser = await chromium.launch({ headless: true });
  afterAll(async () => {
    resetLinkStore();
    await browser.close();
  });
  const css = readFileSync(new URL("../src/agent-session/acpmux/chips/chips.css", import.meta.url), "utf8");
  const file = "/workspace/cmux.json";
  const outside = "/tmp/example/notes.md";
  resetLinkStore();
  seedLinkStore({
    paths: { [file]: { place: "root", folder: false }, [outside]: { place: "outside", folder: false } },
  });
  const markup = renderToStaticMarkup(
    <>
      <p id="plain">Words before cmux.json and after.</p>
      <p id="chips">
        Words before <PathChip path={file} /> and after.
      </p>
      <p>
        <PathChip path={outside} /> <ElsewhereChip path={file} host="example-host" />
      </p>
      <p>
        <UrlChip href="https://github.com/example/project/pull/42">#42</UrlChip>{" "}
        <UrlChip href="https://example.test/docs">Guide</UrlChip>{" "}
        <PathChip path={file} label={<code className="cv-code">parseConfig</code>} />
      </p>
    </>,
  );
  for (const scheme of ["light", "dark"])
    for (const size of [12, 14, 20])
      test(`${scheme}, ${size}px: chips share prose metrics, keep links and explain locality without a lock`, async () => {
        const page = await browser.newPage();
        try {
          await page.setContent(`<style>
            :root { --cv-text: ${scheme === "dark" ? "#eee" : "#222"}; --cv-text-dim: #888; --cv-link: #b37431; --agent-link: #b37431; }
            body { font: ${size}px/1.2 sans-serif; color: var(--cv-text); }
            .cv-code { font-size: 11px; font-weight: 600; padding: 1px 5px; background: #888; }
            ${css}</style>${markup}`);
          const looks = await page.evaluate(() => {
            const plain = document.querySelector("#plain")!;
            return {
              height: document.querySelector("#chips")!.getBoundingClientRect().height,
              plainHeight: plain.getBoundingClientRect().height,
              chips: [...document.querySelectorAll(".cv-chip")].map((chip) => {
                const label = chip.querySelector("code, .cv-chip__label")!;
                const style = getComputedStyle(chip);
                return {
                  size: getComputedStyle(label).fontSize,
                  weight: getComputedStyle(label).fontWeight,
                  background: style.backgroundColor,
                  padding: style.padding,
                  border: style.borderWidth,
                };
              }),
              locks: document.querySelectorAll(".cv-chip__lock").length,
              outside: document.querySelector(".is-outside")?.getAttribute("title"),
              elsewhere: document.querySelector(".is-elsewhere")?.getAttribute("title"),
              hrefs: [...document.querySelectorAll("a")].map((a) => a.getAttribute("href")),
            };
          });
          expect(looks.height).toBeCloseTo(looks.plainHeight, 1);
          for (const look of looks.chips)
            expect(look).toEqual({
              size: `${size}px`,
              weight: "400",
              background: "rgba(0, 0, 0, 0)",
              padding: "0px",
              border: "0px",
            });
          expect(looks.locks).toBe(0);
          expect(looks.outside).toContain("Outside this project");
          expect(looks.outside).toContain(outside);
          expect(looks.elsewhere).toContain("example-host");
          expect(looks.hrefs).toEqual(["https://github.com/example/project/pull/42", "https://example.test/docs"]);
          await page.locator(".is-outside").hover();
          expect(await page.locator(".is-outside").evaluate((node) => getComputedStyle(node).backgroundColor)).toBe(
            "rgba(0, 0, 0, 0)",
          );
        } finally {
          await page.close();
        }
      });
});
