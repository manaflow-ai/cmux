// The running turn's token count reads quieter than its words (agent-pane-turn-tokens-muted.test.tsx),
// resolved in Chromium from the real stylesheets under a host theme: "Thinking" in the theme's
// secondary text, "Working for 35s" in the background activity tone (#27074: 58% of the foreground),
// "· 679.9K tokens" in its tertiary, in tabular numerals.
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { tokenLines, tokenLineMarkup } from "./support/turnTokenLines";

await requireBrowserLane("agent-pane-turn-tokens-muted-browser.test.tsx", async () => {
  setDefaultTimeout(60_000);
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("agent-pane-turn-tokens-muted-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("turn tokens muted", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  // The host's theme (AgentPaneTheme.swift: mutedText is textSecondary, softText textTertiary).
  const theme =
    "--agent-text: rgb(230, 230, 230); --agent-muted: rgb(160, 160, 170); --agent-soft: rgb(110, 110, 120);";

  describe("the count reads quieter than the line's words", () => {
    for (const [name, line] of Object.entries(tokenLines))
      test(name, async () => {
        const page = await browser.newPage();
        try {
          // The static status look: the word Thinking holds still in its muted color, no band.
          await page.setContent(
            `<html data-status-indicators="static" style="${theme}"><head><style>${css}</style></head>` +
              `<body>${tokenLineMarkup(line)}</body></html>`,
          );
          const looks = await page.evaluate(() => {
            const style = (selector: string) => getComputedStyle(document.querySelector(selector)!);
            return {
              words: style(".cv-thinking, .cv-worked__label").color,
              // `--cv-activity-text` as this page resolves it.
              activity: (() => {
                const probe = document.createElement("span");
                probe.style.color = "var(--cv-activity-text)";
                document.querySelector(".cv-thinking, .cv-worked")!.append(probe);
                const color = getComputedStyle(probe).color;
                probe.remove();
                return color;
              })(),
              tokens: style(".cv-worked__tokens").color,
              sep: style(".cv-worked__sep").color,
              numerals: style(".cv-worked__tokens").fontVariantNumeric,
            };
          });
          // The live line keeps the muted token; the line over the turn takes the activity tone.
          expect(looks.words).toBe(name.includes("WorkingFor.tsx") ? looks.activity : "rgb(160, 160, 170)");
          expect(looks.words).not.toBe(looks.tokens);
          expect(looks.tokens).toBe("rgb(110, 110, 120)");
          expect(looks.sep).toBe(looks.tokens);
          expect(looks.numerals).toContain("tabular-nums");
        } finally {
          await page.close();
        }
      });
    test("closes the browser", async () => {
      await browser.close();
    });
  });
});
