// Links in agent replies are blue, period (Leo 2026-10-19, as Claude desktop and Codex): a markdown
// link and a bare URL's chip are a clear blue in a light and a dark page and under any terminal
// theme, which shifts the blue only mildly (its ANSI bright blue is a fifth of it), and they carry
// an underline. A pull request reference shares prose metrics. This loads the real stylesheets in Chromium.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-links-blue.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-links-blue: skipping (run `bunx playwright install chromium`)");
    describe.skip("links blue", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/chips/chips.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  const body =
    `<div class="cv-md"><p>See <a class="cv-link" href="https://example.com">the docs</a>, ` +
    `<a class="cv-link cv-chip is-web" href="https://example.com/x"><span class="cv-chip__label">example.com/x</span></a> and ` +
    `<a class="cv-link cv-chip is-web is-ref" href="https://github.com/o/r/pull/1"><span class="cv-chip__label">o/r#1</span></a>.</p></div>`;
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  // Terminal themes' text, background and bright blue: a stock dark, a light, a theme whose ANSI 12
  // is not blue at all (a monochrome green), and one with no palette.
  const themes = [
    { name: "dark", scheme: "dark", text: "#e6e6e6", ansi12: "#6ab0ff" },
    { name: "light", scheme: "light", text: "#1f1f1f", ansi12: "#2f6fd0" },
    { name: "green mono", scheme: "dark", text: "#33ff66", ansi12: "#33ff66" },
    { name: "no palette", scheme: "light", text: "#222222", ansi12: undefined },
  ] as const;

  for (const theme of themes) {
    test(`links are blue and underlined: ${theme.name}`, async () => {
      const p = await browser!.newPage();
      await p.setContent(`<style>${css}</style>${body}`);
      const looks = await p.evaluate(
        ({ scheme, text, ansi12 }) => {
          const root = document.documentElement;
          root.style.colorScheme = scheme;
          root.style.setProperty("--cmux-text", text);
          if (ansi12) root.style.setProperty("--agent-ansi-12", ansi12);
          // The computed color can be oklab() (color-mix); a canvas pixel gives its sRGB.
          const canvas = document.createElement("canvas").getContext("2d")!;
          const rgb = (color: string) => {
            canvas.clearRect(0, 0, 1, 1);
            canvas.fillStyle = color;
            canvas.fillRect(0, 0, 1, 1);
            // oxlint-disable-next-line unicorn/no-useless-spread -- slice returns a Uint8ClampedArray; the spread makes a plain array that serializes out of the page and that the test destructures.
            return [...canvas.getImageData(0, 0, 1, 1).data.slice(0, 3)];
          };
          return [...document.querySelectorAll<HTMLElement>("a")].map((link) => {
            const label = link.querySelector<HTMLElement>(".cv-chip__label") ?? link;
            const style = getComputedStyle(link);
            return {
              color: rgb(style.color),
              underline: getComputedStyle(label).textDecorationLine,
              background: style.backgroundColor,
              ref: link.classList.contains("is-ref"),
            };
          });
        },
        { scheme: theme.scheme, text: theme.text, ansi12: theme.ansi12 },
      );
      await p.close();
      expect(looks.length).toBe(3);
      for (const look of looks) {
        const [r, g, b] = look.color as [number, number, number];
        // Blue: its blue channel well above red, and above green.
        expect(b - r).toBeGreaterThan(90);
        expect(b).toBeGreaterThan(g);
        expect(look.underline).toContain("underline");
        expect(look.background).toBe("rgba(0, 0, 0, 0)");
      }
    });
  }
});
