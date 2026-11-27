// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// One composer whatever machine the agent runs on (Leo, 2026-11-07: "why can this styling be
// different? ... why does the right one have the prompt suggestion and the left one doesn't?").
// The same chat state on this Mac, on a peer of this Mac's acpmux, over the app's remote wire and on
// Cloud (gallery agent-pane.composer-any-host) must give the composer card the same classes and
// attributes and the same computed outline: its box-shadow (hairline ring, glass material rim and
// depth), fill, frost and corners, at rest and focused (by a real Tab: the stage's code focus lifts no
// ring, FOCUS-RING, src/ui/focusModality.ts), in a dark and a light theme. The suggested
// next prompt shows on every host exactly when the agent sent one, and never when it did not.
//
// Real Chromium from Playwright on the real gallery frame; CI fails the file when it cannot launch
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test ./test/composer-any-host.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { focusByKey } from "./support/focusByKey";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-any-host.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.composer-any-host";
  const HOSTS = ["this-mac", "peer", "remote", "cloud"] as const;
  const PROMPT = ".acpmux-composer > .acpmux-composer-box [contenteditable='true']";
  const SUGGESTION = "Add a test for the retry backoff";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser, params: { variant: "this-mac-rest" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Look = {
    form: Record<string, string>;
    box: Record<string, string>;
    style: Record<string, string>;
    placeholder: string;
  };

  async function look(variant: string, colorScheme: "dark" | "light"): Promise<Look> {
    const page = await browser!.newPage({ viewport: { width: 620, height: 420 } });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, colorScheme, width: 620 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      // The stage focuses the prompt from code, which earns no ring; a key's focus lifts the rim.
      if (variant.endsWith("-focused")) await focusByKey(page, PROMPT);
      return await page.evaluate(() => {
        const form = document.querySelector<HTMLElement>(".acpmux-composer")!;
        const box = form.querySelector<HTMLElement>(":scope > .acpmux-composer-box")!;
        // Every attribute but the per-render ones (React ids, the source line's comment).
        const attributes = (element: HTMLElement) =>
          Object.fromEntries(
            [...element.attributes].filter((a) => a.name !== "id" && a.name !== "style").map((a) => [a.name, a.value]),
          );
        const computed = getComputedStyle(box);
        const style: Record<string, string> = {};
        for (const name of [
          "box-shadow",
          "background-color",
          "background-image",
          "backdrop-filter",
          "-webkit-backdrop-filter",
          "border-radius",
          "border-top-color",
          "border-top-width",
          "outline-style",
        ])
          style[name] = computed.getPropertyValue(name);
        for (const name of ["--acpmux-card-ring", "--acpmux-composer-rim", "--acpmux-composer-glint", "--glass-tint"])
          style[name] = computed.getPropertyValue(name).trim();
        return {
          form: attributes(form),
          box: attributes(box),
          style,
          placeholder: document.querySelector(".acpmux-md-placeholder")?.textContent ?? "",
        };
      });
    } finally {
      await page.close();
    }
  }

  for (const colorScheme of ["dark", "light"] as const) {
    for (const state of ["rest", "focused"] as const) {
      test(`${colorScheme}, ${state}: the composer card is the same on every host`, async () => {
        const local = await look(`this-mac-${state}`, colorScheme);
        // The stage really is in the state it names, so the comparison is not of two resting cards.
        expect(local.style["box-shadow"]).not.toBe("none");
        for (const host of HOSTS.slice(1)) {
          const other = await look(`${host}-${state}`, colorScheme);
          expect({ host, form: other.form, box: other.box }).toEqual({ host, form: local.form, box: local.box });
          expect({ host, style: other.style }).toEqual({ host, style: local.style });
        }
      });
    }
  }

  test("the focused card's ring differs from the resting one (the only rim difference is focus)", async () => {
    const rest = await look("this-mac-rest", "dark");
    const focused = await look("this-mac-focused", "dark");
    expect(focused.style["--acpmux-card-ring"]).not.toBe(rest.style["--acpmux-card-ring"]);
  });

  test("the agent's suggested next prompt shows on every host exactly when the agent sent one", async () => {
    for (const host of HOSTS) {
      expect({ host, shown: (await look(`${host}-suggested`, "dark")).placeholder }).toEqual({
        host,
        shown: expect.stringContaining(SUGGESTION),
      });
      expect({ host, shown: (await look(`${host}-rest`, "dark")).placeholder.includes(SUGGESTION) }).toEqual({
        host,
        shown: false,
      });
    }
  });
});
