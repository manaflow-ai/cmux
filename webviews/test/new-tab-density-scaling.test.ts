// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-density-scaling.test.ts", async () => {
  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser: browsers.get("chromium")! });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const engine of ["chromium", "webkit"]) {
    test(`${engine}: the whole composer area scales from Default, including create buttons`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width: 1600, height: 1000 } });
      const port = (vite.httpServer!.address() as { port: number }).port;
      try {
        const results: {
          scale: number;
          elements: { name: string; width: number; height: number }[];
          boxWidth: number;
          centered: number;
          buttonsCentered: number;
          spacing: number;
          gap: number;
          buttons: Record<string, number>[];
        }[] = [];
        for (const scale of [0.8, 1, 1.2]) {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", {
              variant: `density-${Math.round(scale * 100)}`,
              width: 1400,
              frame: "component",
            })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".nt-popover .nt-row").first().waitFor();
          await page.evaluate(() => document.fonts.ready);
          results.push(
            await page.evaluate((scale) => {
              const composer = document.querySelector<HTMLElement>(".nt-composer")!;
              const create = document.querySelector<HTMLElement>(".nt-create")!;
              const box = composer.getBoundingClientRect();
              const group = create.getBoundingClientRect();
              const buttons = [...create.querySelectorAll<HTMLElement>(".nt-tool")];
              const buttonBounds = buttons.map((button) => button.getBoundingClientRect());
              const drawn = (element: Element, property: string) => {
                let zoom = 1;
                for (let ancestor: Element | null = element; ancestor; ancestor = ancestor.parentElement)
                  zoom *= parseFloat(getComputedStyle(ancestor).zoom) || 1;
                return parseFloat(getComputedStyle(element).getPropertyValue(property)) * zoom;
              };
              // Walk every descendant so newly added controls join the guard automatically.
              const elements = [composer, create, document.querySelector<HTMLElement>(".nt-popover")!]
                .flatMap((root) => [root, ...root.querySelectorAll("*")])
                .filter((element) => {
                  const bounds = element.getBoundingClientRect();
                  return bounds.width > 0 && bounds.height > 0 && getComputedStyle(element).visibility === "visible";
                })
                .map((element) => ({
                  name: `${element.tagName}.${element.getAttribute("class") ?? ""}`,
                  width: element.getBoundingClientRect().width,
                  height: element.getBoundingClientRect().height,
                }));
              return {
                scale,
                elements,
                boxWidth: box.width,
                centered: (group.left + group.right - box.left - box.right) / 2,
                buttonsCentered: (buttonBounds[0]!.left + buttonBounds.at(-1)!.right - box.left - box.right) / 2,
                spacing: group.top - box.bottom,
                gap: buttonBounds[1]!.left - buttonBounds[0]!.right,
                buttons: buttons.map((button): Record<string, number> => ({
                  ...Object.fromEntries(
                    [
                      "font-size",
                      "padding-top",
                      "padding-right",
                      "padding-bottom",
                      "padding-left",
                      "gap",
                      "border-top-left-radius",
                    ].map((property) => [property, drawn(button, property)]),
                  ),
                  width: button.getBoundingClientRect().width,
                  height: button.getBoundingClientRect().height,
                  icon: button.querySelector("svg")!.getBoundingClientRect().width,
                })),
              };
            }, scale),
          );
        }
        const reference = results[1]!;
        // The fixture must exercise both chips above, the box, footer chips and suggestions.
        expect(await page.locator(".nt-location .acpmux-location-picker").count()).toBeGreaterThanOrEqual(2);
        expect(await page.locator(".nt-box").count()).toBe(1);
        expect(await page.locator(".nt-pickers button").count()).toBeGreaterThan(0);
        expect(await page.locator(".nt-popover .nt-row").count()).toBeGreaterThan(0);
        expect(reference.buttons).toHaveLength(3);
        for (const result of results) {
          const where = `${engine} zoom ${result.scale}`;
          expect(Math.abs(result.centered), where).toBeLessThanOrEqual(1);
          expect(Math.abs(result.buttonsCentered), where).toBeLessThanOrEqual(1);
          for (const key of ["spacing", "gap"] as const)
            expect(Math.abs(result[key] - reference[key] * result.scale), `${where} ${key}`).toBeLessThanOrEqual(1);
          expect(
            result.elements.map((element) => element.name),
            where,
          ).toEqual(reference.elements.map((element) => element.name));
          for (const [index, element] of result.elements.entries())
            for (const dimension of ["width", "height"] as const)
              expect(
                Math.abs(element[dimension] - reference.elements[index]![dimension] * result.scale),
                `${where} ${element.name} ${dimension}`,
              ).toBeLessThanOrEqual(1);
          for (const [index, button] of result.buttons.entries())
            for (const [property, value] of Object.entries(button)) {
              expect(
                Math.abs(value - (reference.buttons[index]![property]! * result.boxWidth) / reference.boxWidth),
                `${where} create ${index} ${property}`,
              ).toBeLessThanOrEqual(1);
            }
        }
      } finally {
        await page.close();
      }
    });

    test(`${engine}: suggestion width, alignment and proportions follow the composer zoom`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width: 1600, height: 1000 } });
      const port = (vite.httpServer!.address() as { port: number }).port;
      const results: {
        scale: number;
        boxWidth: number;
        popupWidth: number;
        left: number;
        glyph: number;
        text: number;
        prompt: number;
        row: number;
        plus: number;
        send: number;
        stroke: number;
        layout: {
          composerZoom: string;
          composerWidth: string;
          column: string;
          screenWidth: number;
          screenPadding: string;
          widthCandidates: { width: string; accepted: boolean; computed: string; drawn: number }[];
        };
      }[] = [];
      for (const scale of [0.8, 1, 1.2]) {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", {
            variant: `density-${Math.round(scale * 100)}`,
            width: 1400,
            frame: "component",
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".nt-popover .nt-row").first().waitFor();
        results.push(
          await page.evaluate((scale) => {
            const composer = document.querySelector<HTMLElement>(".nt-composer")!;
            const box = document.querySelector<HTMLElement>(".nt-box")!.getBoundingClientRect();
            const popover = document.querySelector<HTMLElement>(".nt-popover")!;
            const popup = popover.getBoundingClientRect();
            const row = popover.querySelector<HTMLElement>(".nt-row")!;
            const glyph = row.querySelector<HTMLElement>(".nt-row-glyph")!;
            const prompt = composer.querySelector<HTMLElement>(".nt-field")!;
            const zoom = parseFloat(getComputedStyle(popover).zoom);
            const plus = composer.querySelector<HTMLElement>(".acpmux-newtab-plus .acpmux-icon")!;
            const send = composer.querySelector<HTMLElement>(".acpmux-send .acpmux-icon")!;
            const screen = composer.closest<HTMLElement>(".nt-screen")!;
            const composerStyle = getComputedStyle(composer);
            const layout = {
              composerZoom: composerStyle.zoom,
              composerWidth: composerStyle.width,
              column:
                composerStyle.getPropertyValue("--cmux-composer-column") ||
                composerStyle.getPropertyValue("--cv-column"),
              screenWidth: screen.getBoundingClientRect().width,
              screenPadding: getComputedStyle(screen).paddingInline,
            };
            const savedStyle = composer.getAttribute("style");
            const widthCandidates = [
              "800px",
              "calc(100cqw / var(--cmux-composer-zoom, 1))",
              "calc(100% / var(--cmux-composer-zoom, 1))",
            ].map((width) => {
              composer.style.width = width;
              composer.style.maxWidth = "none";
              return {
                width,
                accepted: CSS.supports("width", width),
                computed: getComputedStyle(composer).width,
                drawn: composer.getBoundingClientRect().width,
              };
            });
            if (savedStyle === null) composer.removeAttribute("style");
            else composer.setAttribute("style", savedStyle);
            return {
              scale,
              boxWidth: box.width,
              popupWidth: popup.width,
              left: popup.left - box.left,
              glyph: glyph.getBoundingClientRect().width,
              text: parseFloat(getComputedStyle(row).fontSize) * zoom,
              prompt: parseFloat(getComputedStyle(prompt).fontSize) * zoom,
              row: row.getBoundingClientRect().height,
              plus: plus.getBoundingClientRect().width,
              send: send.getBoundingClientRect().width,
              stroke: parseFloat(getComputedStyle(send).strokeWidth),
              layout: {
                ...layout,
                widthCandidates,
              },
            };
          }, scale),
        );
      }
      const reference = results[1]!;
      expect(reference.plus).toBeCloseTo(16, 1);
      expect(reference.send).toBeCloseTo(16, 1);
      expect(reference.stroke).toBeCloseTo(1.5, 1);
      for (const result of results) {
        expect(Math.abs(result.popupWidth - result.boxWidth)).toBeLessThan(1);
        expect(Math.abs(result.left)).toBeLessThan(1);
        expect(
          Math.abs(result.boxWidth - reference.boxWidth * result.scale),
          JSON.stringify({ engine, result, reference }),
        ).toBeLessThan(1);
        for (const key of ["glyph", "text", "prompt", "row", "plus", "send"] as const) {
          expect(Math.abs(result[key] - reference[key] * result.scale)).toBeLessThan(0.5);
        }
      }
      await page.close();
    });
  }
});
