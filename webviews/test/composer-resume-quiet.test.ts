// Resume beside the mic is a plain line glyph like the mic, never a filled disc (cmux#51039; the
// person, 2026-11-22: "i dont like how jarring this button is here for resuming the session? we
// should make it sure it matches the other icons here"). Measured in the gallery's real composer, in
// Claude's and Codex's looks and at every density: the composer's Send slot is given Resume's classes
// and its ▶, and must draw as the mic does (fill, colour, box, glyph size, stroke, centre line, inset)
// at rest and under the pointer.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { pageDensities } from "../src/gallery/pageDensityFixtures";

await requireBrowserLane("composer-resume-quiet.test.ts", async () => {
  setDefaultTimeout(300_000);
  const ENTRY = "agent-pane.feel-plan-tray";
  const VARIANT = "one";
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const look of ["claude", "codex"] as const)
    for (const density of pageDensities)
      test(`${look}, ${density.name}: Resume draws as the mic does`, async () => {
        const port = (server.httpServer!.address() as { port: number }).port;
        const page = await browser.newPage({
          viewport: { width: 900, height: 720 },
          deviceScaleFactor: 2,
          reducedMotion: "reduce",
        });
        try {
          await installPaintedFrames(page);
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: "normal" })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          if (look === "codex") {
            await page.evaluate(async () => {
              const source = "/gallery/src/agent-session/acpmux/composerLook.ts";
              const { setPreviewComposerLook } = await import(/* @vite-ignore */ source);
              setPreviewComposerLook("codex");
            });
            await page.locator('.acpmux-composer[data-composer-look="codex"]').waitFor();
          }
          await page.evaluate((value) => {
            const root = document.documentElement;
            for (const name of ["--cmux-density-scale", "--cmux-density-text-scale", "--cmux-row-icon-scale"])
              root.style.setProperty(name, String(value));
            window.dispatchEvent(new Event("cmux-ui-scale-change"));
          }, density.scale);
          // The Send slot (Stop while the fixture's turn runs) becomes Resume, as Composer.tsx draws it.
          // React may draw the slot again (the look switch, the turn's clock), so the classes are kept on.
          await page.evaluate(() => {
            const keep = () => {
              const slot = document.querySelector<HTMLButtonElement>(".acpmux-composer-actions .acpmux-send");
              if (!slot || slot.classList.contains("acpmux-resume")) return;
              slot.className = "acpmux-send acpmux-send-ready acpmux-resume";
              slot.removeAttribute("data-escape-armed");
              slot.disabled = false;
            };
            keep();
            new MutationObserver(keep).observe(document.body, {
              subtree: true,
              childList: true,
              attributes: true,
              attributeFilter: ["class"],
            });
          });
          // The controls' hover fades are not what this measures: each read is of the settled state.
          await page.addStyleTag({ content: ".acpmux-composer-actions * { transition: none !important; }" });
          await page.waitForFunction(() => document.querySelector(".acpmux-composer-actions .acpmux-resume"));
          await page.evaluate(() => window.cmuxPaintFrame());
          const read = (hover: boolean) =>
            page.evaluate((hovered) => {
              const resume = document.querySelector<HTMLElement>(".acpmux-composer-actions .acpmux-resume")!;
              const mic = document.querySelector<HTMLElement>(".acpmux-composer-actions .acpmux-mic")!;
              const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
              const look = (button: HTMLElement) => {
                const style = getComputedStyle(button);
                const svg = button.querySelector("svg")!;
                const glyph = svg.getBoundingClientRect();
                const r = button.getBoundingClientRect();
                return {
                  background: style.backgroundColor,
                  color: style.color,
                  radius: style.borderTopLeftRadius,
                  w: r.width,
                  h: r.height,
                  cy: r.top + r.height / 2,
                  bottomInset: box.bottom - r.bottom,
                  glyph: glyph.width,
                  stroke: getComputedStyle(svg).strokeWidth,
                  hovered,
                };
              };
              return { resume: look(resume), mic: look(mic), micRight: box.right - mic.getBoundingClientRect().right };
            }, hover);
          const rest = await read(false);
          const off: string[] = [];
          const same = (what: string, a: unknown, b: unknown) => {
            if (a !== b) off.push(`${what}: ${String(a)} vs the mic's ${String(b)}`);
          };
          const near = (what: string, a: number, b: number, slack = 0.5) => {
            if (Math.abs(a - b) > slack) off.push(`${what}: ${a} vs the mic's ${b}`);
          };
          same("fill at rest", rest.resume.background, rest.mic.background);
          same("colour at rest", rest.resume.color, rest.mic.color);
          same("corner", rest.resume.radius, rest.mic.radius);
          near("width", rest.resume.w, rest.mic.w);
          near("height", rest.resume.h, rest.mic.h);
          near("centre line", rest.resume.cy, rest.mic.cy);
          near("bottom inset", rest.resume.bottomInset, rest.mic.bottomInset);
          near("glyph size", rest.resume.glyph, rest.mic.glyph);
          same("stroke", rest.resume.stroke, rest.mic.stroke);
          // Under the pointer each takes the same quiet pill and ink.
          await page.hover(".acpmux-composer-actions .acpmux-resume");
          await page.evaluate(() => window.cmuxPaintFrame());
          const resumeHover = (await read(true)).resume;
          await page.hover(".acpmux-composer-actions .acpmux-mic");
          await page.evaluate(() => window.cmuxPaintFrame());
          const micHover = (await read(true)).mic;
          same("fill under the pointer", resumeHover.background, micHover.background);
          same("colour under the pointer", resumeHover.color, micHover.color);
          expect(off).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
