// Session Info (session-info/SessionInfo.tsx, sessionInfo.css) is liquid glass wherever it sits, never
// opaque (Leo, 2026-10-21: the panel "is still SOLID"; "glass, never opaque"): over the chat and pushed
// beside it, the panel is a `.ui-glass` (ui/glass/glass.css) whose fill lets what is behind it show, and
// a section is no box of its own, neither a fill nor a border (Leo, 2026-10-22: "tmi and too many
// boxes"). Under Reduce Transparency the panel is the opaque theme surface.
//
// Real Chromium loads glass.css and sessionInfo.css over the panel's own markup (SessionInfoPanel). CI
// fails the file when it cannot launch the engine (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/session-info-glass.test.tsx
import { readFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser, type Page } from "playwright";
import { SessionInfoPanel, type SessionInfoPlacement } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-glass.test.tsx", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-info-glass: skipping (run `bunx playwright install chromium`)");
    describe.skip("session info glass", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  const css = ["ui/glass/glass.css", "agent-session/acpmux/session-info/sessionInfo.css"]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function open(placement: SessionInfoPlacement): Promise<Page> {
    const panel = renderToStaticMarkup(
      <SessionInfoPanel width={320} placement={placement}>
        <div className="acpmux-session-info__body" data-layout="glance">
          <div className="acpmux-session-info-group" data-group="about">
            <section className="acpmux-session-info-section">Environment</section>
          </div>
          <div className="acpmux-session-info-group" data-group="made">
            <section className="acpmux-session-info-section">Changes</section>
          </div>
        </div>
      </SessionInfoPanel>,
    );
    expect(panel).toContain('class="ui-glass ui-glass-floats acpmux-session-info"');
    const page = await browser!.newPage();
    // The host's tokens on an opaque window: a solid page and theme surface, so only the panel's own
    // material decides whether the transcript behind it shows.
    await page.setContent(
      `<style>:root{--cmux-surface-solid:rgb(30, 30, 30);--agent-page-bg:rgb(30, 30, 30);--agent-text:rgb(236, 236, 240);--agent-border:rgba(255, 255, 255, 0.14);--surface-blur:blur(20px) saturate(1.8)}${css}</style><div class="acpmux-shell" style="position:relative;display:flex;justify-content:flex-end;height:600px">${panel}</div>`,
    );
    return page;
  }
  const look = (page: Page) =>
    page.evaluate(() => {
      const panel = getComputedStyle(document.querySelector(".acpmux-session-info")!);
      const card = getComputedStyle(document.querySelector(".acpmux-session-info-section")!);
      const blocks = [...document.querySelectorAll(".acpmux-session-info-group")].map(
        (block) => getComputedStyle(block).borderTopStyle,
      );
      return {
        panel: { background: panel.backgroundColor, filter: panel.backdropFilter },
        card: { background: card.backgroundColor, image: card.backgroundImage, border: card.borderTopStyle },
        blocks,
      };
    });
  /// A computed color's alpha (`rgb(...)` is 1).
  const alpha = (color: string) => {
    const match = /^(?:rgba|color)\(.*[,/]\s*([\d.]+)\s*\)$/.exec(color);
    return match ? Number(match[1]) : color === "transparent" ? 0 : 1;
  };

  for (const placement of ["overlay", "push"] as const) {
    test(`${placement}: the panel is glass, never opaque, and a section is no box: no fill, no border`, async () => {
      const page = await open(placement);
      const { panel, card, blocks } = await look(page);
      expect(panel.filter).toContain("blur");
      expect(alpha(panel.background)).toBeGreaterThan(0);
      expect(alpha(panel.background)).toBeLessThan(1);
      expect(card).toEqual({ background: "rgba(0, 0, 0, 0)", image: "none", border: "none" });
      // The blocks are split by one hairline, never boxed: none over the first.
      expect(blocks).toEqual(["none", "solid"]);
      await page.close();
    });

    test(`${placement}: under Reduce Transparency the panel is the opaque theme surface`, async () => {
      const page = await open(placement);
      await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
      expect((await look(page)).panel).toEqual({ background: "rgb(30, 30, 30)", filter: "none" });
      await page.close();
    });
  }
});
