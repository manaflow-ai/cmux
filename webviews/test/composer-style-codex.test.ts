// The composer's two styles as drawn (Settings > Agent Chat > Composer Style, cmux.json
// `agentPane.display.composer.style`, chatDisplay.ts `composerStyle`; Leo 2026-10-21: "we can have the alt composer like chatgpt styled but for now just
// have "minimal" be the claude thing").
// It renders the gallery's `agent-pane.composer-style` entry (a new Codex chat: a folder and this
// computer, GPT-6-Astra on High, Full access) in Chromium, light and dark, and measures:
//   - minimal (the default): no style on the composer, the strip a tab spanning the card (no tray), the mode and
//     model in the quiet row under the box;
//   - codex: the strip is a tray, set in from the box's sides and tucked under its top edge, glass
//     (never opaque), naming the folder and the computer; no quiet row; one row in the box under the
//     prompt reading +, the mode, then the model with its harness mark, the mic and Send, the mode
//     left of the middle and the model right of it; Full access in the theme's accent, never orange;
//   - both draw the same controls (one + menu, one mode menu, one model button, one strip).
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Box = { left: number; right: number; top: number; bottom: number };
type Drawn = {
  style: string | null;
  box: Box;
  prompt: Box;
  strip: (Box & { background: string; places: string[] }) | null;
  foot: Box | null;
  controls: Record<string, Box | null>;
  modeColor: string;
  accent: string;
  modelMark: boolean;
  shared: number[];
};

await requireBrowserLane("composer-style-codex.test.ts", async () => {
  /** Runs in the page: the composer's parts and where they draw. */
  function measure(): Drawn {
    const rect = (element: Element | null | undefined): Box | null => {
      if (!element) return null;
      const css = getComputedStyle(element);
      if (css.display === "none" || css.visibility !== "visible") return null;
      const { left, right, top, bottom, width, height } = element.getBoundingClientRect();
      return width > 0 && height > 0 ? { left, right, top, bottom } : null;
    };
    const form = document.querySelector<HTMLElement>("form.acpmux-composer")!;
    const box = form.querySelector(":scope > .acpmux-composer-box")!;
    const strip = form.querySelector(":scope > .acpmux-composer-strip");
    const stripBox = rect(strip);
    const mode = box.querySelector(".acpmux-access-trigger") ?? form.querySelector(".acpmux-access-trigger");
    const probe = document.createElement("span");
    probe.style.color = "var(--agent-lit-glyph, var(--agent-accent, var(--agent-text)))";
    form.append(probe);
    const accent = getComputedStyle(probe).color;
    probe.remove();
    const mark = box.querySelector(".acpmux-model .acpmux-picker-button .agent-mark");
    return {
      style: form.getAttribute("data-composer-style"),
      box: rect(box)!,
      prompt: rect(box.querySelector(".acpmux-md-field"))!,
      strip:
        strip && stripBox
          ? {
              ...stripBox,
              background: getComputedStyle(strip).backgroundColor,
              places: [...strip.querySelectorAll(".acpmux-location-picker")]
                .filter((place) => rect(place) !== null)
                .map((place) => place.textContent?.trim() ?? ""),
            }
          : null,
      foot: rect(form.querySelector(".acpmux-composer-foot")),
      controls: {
        plus: rect(box.querySelector(".acpmux-composer-plus .acpmux-picker-button")),
        mode: rect(box.querySelector(".acpmux-access-trigger")),
        model: rect(box.querySelector(".acpmux-model .acpmux-picker-button")),
        mic: rect(box.querySelector(".acpmux-mic")),
        send: rect(box.querySelector(".acpmux-send")),
      },
      modeColor: mode ? getComputedStyle(mode).color : "",
      accent,
      modelMark: mark !== null && rect(mark) !== null,
      shared: [
        ".acpmux-composer-strip .acpmux-composer-context",
        ".acpmux-composer-plus",
        ".acpmux-model .acpmux-picker-button",
        ".acpmux-access-trigger",
      ].map((selector) => form.querySelectorAll(selector).length),
    };
  }

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-style-codex: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer styles", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-style", { variant, theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-style", { browser, params: { variant: "minimal" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, scheme: string, width = 760): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 320 }, reducedMotion: "reduce" });
    await page.goto(stageURL(variant, scheme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-composer-strip .acpmux-location-picker").first().waitFor();
    await page.locator(".acpmux-access-trigger").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  };
  const read = async (variant: string, scheme: string) => {
    const page = await open(variant, scheme);
    const drawn = await page.evaluate(measure);
    await page.close();
    console.log(JSON.stringify({ variant, scheme, ...drawn }));
    return drawn;
  };

  for (const scheme of ["light", "dark"]) {
    test(`minimal (${scheme}): no style and no tray; the mode and model in the quiet row under the box`, async () => {
      const drawn = await read("minimal", scheme);
      expect(drawn.style).toBeNull();
      // The strip is the minimal style's tab, as wide as the card.
      expect(drawn.strip).not.toBeNull();
      expect(Math.abs(drawn.strip!.left - drawn.box.left)).toBeLessThan(1);
      expect(Math.abs(drawn.strip!.right - drawn.box.right)).toBeLessThan(1);
      expect(drawn.foot).not.toBeNull();
      expect(drawn.foot!.top).toBeGreaterThanOrEqual(drawn.box.bottom - 0.5);
      expect(drawn.controls.mode).toBeNull();
      expect(drawn.controls.model).toBeNull();
    });

    test(`codex (${scheme}): a glass tray above the box, and + and the mode, then the model, the mic and Send in its row`, async () => {
      const drawn = await read("codex", scheme);
      expect(drawn.style).toBe("codex");
      const { strip, box, prompt, controls } = drawn;
      // The tray: set in from the box's sides, its top above the box's, tucked under the box's edge.
      expect(strip).not.toBeNull();
      expect(strip!.left).toBeGreaterThan(box.left + 4);
      expect(strip!.right).toBeLessThan(box.right - 4);
      expect(strip!.top).toBeLessThan(box.top - 16);
      expect(strip!.bottom).toBeGreaterThan(box.top);
      // Glass, never opaque.
      const alpha = /rgba?\([^)]*?,\s*([\d.]+)\)$/.exec(strip!.background)?.[1];
      expect(alpha === undefined ? 1 : Number(alpha)).toBeLessThan(1);
      // The folder and the computer.
      expect(strip!.places.length).toBeGreaterThanOrEqual(2);
      expect(strip!.places.join(" ")).toContain("atlas-web");
      // No quiet row: the controls sit in the box, under the prompt.
      expect(drawn.foot).toBeNull();
      const row = ["plus", "mode", "model", "mic", "send"].map((name) => ({ name, at: controls[name] }));
      for (const { name, at } of row) {
        expect({ name, drawn: at !== null }).toEqual({ name, drawn: true });
        expect({ name, under: at!.top >= prompt.bottom - 0.5 }).toEqual({ name, under: true });
        expect({ name, inside: at!.left >= box.left && at!.right <= box.right && at!.bottom <= box.bottom }).toEqual({
          name,
          inside: true,
        });
      }
      // Left to right as Codex's: +, the mode, then the model, the mic and Send.
      const lefts = row.map(({ at }) => at!.left);
      expect(lefts).toEqual([...lefts].sort((a, b) => a - b));
      const middle = (box.left + box.right) / 2;
      expect(controls.mode!.right).toBeLessThan(middle);
      expect(controls.model!.left).toBeGreaterThan(middle);
      // The model button shows the harness's mark, as Codex's shows its bolt.
      expect(drawn.modelMark).toBe(true);
      // Full access in the theme's accent, where Codex draws orange.
      expect(drawn.modeColor).toBe(drawn.accent);
    });
  }

  test("both styles draw the same controls", async () => {
    const plain = await read("minimal", "light");
    const codex = await read("codex", "light");
    expect(codex.shared).toEqual(plain.shared);
    expect(codex.shared).toEqual([1, 1, 1, 1]);
  });
});
