// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// Another agent's message reads at one steady brightness (Leo, 2026-11-03, on a received message's
// card drawn dim at rest and bright under the pointer: "i dont think this should light up/dim based
// off if ur hovered onit or otherwise"). Pointing at or focusing a received line, its opened card,
// its sender chip or the "Received N messages" row may reveal controls (the hover actions, the
// chevron, Copy) and draw a hover plate, but never changes any text's or card's colour, opacity or
// filter. Measured in the page from the real transcript: gallery entries
// agent-pane.incoming-message-disclosure (a-shipped-open) and agent-pane.received-messages
// (collapsed, level-1, level-2). design/chat-transcript.md "Messages from other agents".
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("received-message-steady-tone-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("received message steady tone", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.received-messages", { browser, params: { variant: "collapsed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** What is measured: every received message and every "Received N messages" row head. */
  const SCOPE = ".cv-received, .cv-lane-batch__toggle";
  /** Controls that hover may reveal or light: the hover actions, the chevron, Copy. */
  const CONTROLS = ".cv-received__hover, .cv-rotor, .cv-tool__chevron, .cv-card-copy";
  /** What the pointer visits: each line, each opened card, each sender chip, each row head. */
  const TARGETS = [
    ".cv-received > .cv-disclosure__line",
    ".cv-received .cv-disclosure__panel",
    ".cv-received .cv-agent-tag",
    ".cv-lane-batch__toggle",
  ];

  const open = async (entry: string, variant: string) => {
    const page = await browser.newPage({ viewport: { width: 760, height: 1400 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    // Each state is read as it settles: no transition is mid-way when it is read.
    await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
    return page;
  };

  /** Every measured element's colour, opacity and filter, by its place in the page. */
  const tones = (page: Page) =>
    page.evaluate(
      ({ scope, controls }) => {
        const out: Record<string, string> = {};
        const roots = [...document.querySelectorAll<HTMLElement>(scope)].filter(
          (root) => !root.parentElement?.closest(scope),
        );
        roots.forEach((root, r) => {
          [root, ...root.querySelectorAll<Element>("*")].forEach((element, index) => {
            if (element.closest(controls)) return;
            const style = getComputedStyle(element);
            const name = `${r}.${index} <${element.tagName.toLowerCase()} class="${element.getAttribute("class") ?? ""}"> "${(element.textContent ?? "").trim().slice(0, 24)}"`;
            out[name] = `color ${style.color} | opacity ${style.opacity} | filter ${style.filter} | fill ${style.fill}`;
          });
        });
        return out;
      },
      { scope: SCOPE, controls: CONTROLS },
    );

  /** Moves the pointer off every measured element and drops the focus a play's click left. */
  const rest = async (page: Page) => {
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur?.());
    await page.mouse.move(1, 1);
    const clear = await page.evaluate((scope) => !document.elementFromPoint(1, 1)?.closest(scope), SCOPE);
    expect(clear).toBe(true);
    return tones(page);
  };

  const differences = (before: Record<string, string>, after: Record<string, string>, what: string) =>
    Object.keys(before)
      .filter((key) => after[key] !== before[key])
      .map((key) => `${what}: ${key}\n    rest  ${before[key]}\n    now   ${after[key]}`);

  const SCENES: [string, string][] = [
    ["agent-pane.incoming-message-disclosure", "a-shipped-open"],
    ["agent-pane.received-messages", "collapsed"],
    ["agent-pane.received-messages", "level-1"],
    ["agent-pane.received-messages", "level-2"],
  ];

  for (const [entry, variant] of SCENES)
    test(`${entry} ${variant}: hover and focus leave every received text and card at its rest tone`, async () => {
      const page = await open(entry, variant);
      try {
        const base = await rest(page);
        expect(Object.keys(base).length).toBeGreaterThan(0);
        const changed: string[] = [];
        let visited = 0;
        for (const selector of TARGETS) {
          const all = page.locator(selector);
          const count = await all.count();
          for (let index = 0; index < count; index += 1) {
            const target = all.nth(index);
            if (!(await target.isVisible())) continue;
            const label = `${selector} #${index}`;
            await rest(page);
            await target.hover();
            visited += 1;
            changed.push(...differences(base, await tones(page), `hover ${label}`));
          }
        }
        // Focus: the line's own toggle, as Tab or a click leaves it.
        const toggles = page.locator(".cv-received > .cv-disclosure__line .cv-disclosure__toggle");
        for (let index = 0; index < (await toggles.count()); index += 1) {
          if (!(await toggles.nth(index).isVisible())) continue;
          await rest(page);
          await toggles.nth(index).focus();
          changed.push(...differences(base, await tones(page), `focus toggle #${index}`));
        }
        expect(visited).toBeGreaterThan(0);
        if (changed.length) console.log(changed.slice(0, 40).join("\n"));
        expect(changed).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
