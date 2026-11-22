// A paste anywhere in the agent pane goes into the composer (Leo 2026-10-21: "pastes need to be able
// to paste even when the composer isn't literally focused", "ME PASTING IT DOESNT JUST PASTE RIGHT IN
// THE COMPOSER IMMEDIATELY"). Before, Cmd-V with the keyboard on the transcript, a message or nothing
// at all did nothing: only the focused prompt took a paste. Now Cmd-V outside a field moves the
// keyboard into the prompt (caret at the end) so the paste lands there, and a paste the page still
// gets outside any field is put into the prompt: text as typed, an image as one chip and never the
// `<img>` or markdown a browser copies with it. A text field elsewhere keeps its own paste.
//
// The real agent pane (vite.config.acpmux-pane.mjs) with a stand-in host and the in-page mock
// transport. Chromium and WebKit; CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-paste-anywhere.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-paste-anywhere.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-paste-anywhere: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("agent pane paste anywhere", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const PROMPT = ".acpmux-composer-prompt .ProseMirror";

  /// The pane with one sent prompt in its transcript, the keyboard on that message.
  async function chat(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      const w = window as unknown as Record<string, unknown>;
      w.webkit = { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } };
      w.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: false }) };
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(PROMPT).waitFor();
    await page.waitForFunction(() => document.activeElement?.classList.contains("ProseMirror"));
    await page.keyboard.type("compare the retry policies");
    await page.keyboard.press("Enter");
    const bubble = page.locator(".cv-user__bubble", { hasText: "compare the retry policies" });
    await bubble.waitFor();
    await page.waitForFunction((selector) => document.querySelector(selector)?.textContent === "", PROMPT);
    // A click on the message, as a reader does: it takes the keyboard out of the composer.
    await bubble.click();
    await page.evaluate(() => getSelection()?.removeAllRanges());
    expect(await inPrompt(page)).toBe(false);
    return page;
  }

  const inPrompt = (page: Page) =>
    page.evaluate(() => document.activeElement?.closest(".acpmux-composer-prompt") != null);
  /// The prompt's typed text: an attachment in it is its chip, whose own text (a failed original's Retry,
  /// #28833) is no text of the prompt's.
  const promptText = (page: Page) =>
    page.locator(PROMPT).evaluate((node) => {
      const copy = node.cloneNode(true) as Element;
      for (const chip of copy.querySelectorAll("[data-inline-attachment]")) chip.remove();
      return copy.textContent ?? "";
    });

  /// Dispatches the paste the app's Paste sends to the focused element, carrying `clipboard`; a PNG
  /// drawn in the page stands for a copied image. Returns whether the page cancelled it.
  function paste(page: Page, clipboard: { image?: boolean; html?: string; plain?: string }) {
    return page.evaluate(async ({ image, html, plain }) => {
      const data = new DataTransfer();
      if (image) {
        const canvas = document.createElement("canvas");
        canvas.width = 32;
        canvas.height = 24;
        const context = canvas.getContext("2d")!;
        context.fillStyle = "#3a7";
        context.fillRect(0, 0, 32, 24);
        const blob = await new Promise<Blob>((done) => canvas.toBlob((made) => done(made!), "image/png"));
        data.items.add(new File([blob], "image.png", { type: "image/png" }));
      }
      if (html) data.setData("text/html", html);
      if (plain) data.setData("text/plain", plain);
      const event = new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data });
      // An engine whose constructor drops the clipboard still gets it, as a person's paste has it.
      if (!event.clipboardData) Object.defineProperty(event, "clipboardData", { value: data });
      (document.activeElement ?? document.body).dispatchEvent(event);
      return event.defaultPrevented;
    }, clipboard);
  }

  for (const [name] of engines)
    describe(name, () => {
      test("text pasted with the keyboard on the transcript goes into the composer, which takes focus", async () => {
        const page = await chat(browsers.get(name)!);
        expect(await paste(page, { plain: "why does the second retry wait?" })).toBe(true);
        expect(await promptText(page)).toBe("why does the second retry wait?");
        expect(await inPrompt(page)).toBe(true);
        // The caret is after the pasted text: typing goes on from there.
        await page.keyboard.type(" Explain");
        expect(await promptText(page)).toBe("why does the second retry wait? Explain");
        await page.close();
      });

      test("text pasted outside the composer goes at the end of the draft already there", async () => {
        const page = await chat(browsers.get(name)!);
        await page.locator(PROMPT).click();
        await page.keyboard.type("first part");
        await page.keyboard.press("Home");
        await page.locator(".cv-user__bubble").first().click();
        expect(await inPrompt(page)).toBe(false);
        await paste(page, { plain: " second part" });
        expect(await promptText(page)).toBe("first part second part");
        await page.close();
      });

      test("Cmd-V outside a field moves the keyboard into the composer before the paste", async () => {
        const page = await chat(browsers.get(name)!);
        await page.keyboard.press("Meta+v");
        expect(await inPrompt(page)).toBe(true);
        await page.close();
      });

      test("an image copied from a browser is one image chip and no text", async () => {
        const page = await chat(browsers.get(name)!);
        expect(
          await paste(page, {
            image: true,
            html: '<meta charset="utf-8"><img src="https://example.com/shot.png" alt="Screenshot · 778×696">',
            plain: '![Screenshot · 778×696]([image] "Screenshot · 778×696")',
          }),
        ).toBe(true);
        // The image goes in the prompt at the caret (the default inline view), not the strip as well.
        const chips = page.locator(`${PROMPT} [data-inline-attachment] img`);
        await chips.first().waitFor();
        expect(await chips.count()).toBe(1);
        expect(await page.locator(".acpmux-attachments .acpmux-attachment-image").count()).toBe(0);
        expect(await promptText(page)).toBe("");
        expect(await inPrompt(page)).toBe(true);
        await page.close();
      });

      test("an image copied from a browser and pasted in the focused composer puts no markdown in it", async () => {
        const page = await chat(browsers.get(name)!);
        await page.locator(PROMPT).click();
        await paste(page, {
          image: true,
          html: '<img src="https://example.com/shot.png" alt="Screenshot · 778×696">',
          plain: 'see ![Screenshot · 778×696]([image] "Screenshot · 778×696")',
        });
        const chips = page.locator(`${PROMPT} [data-inline-attachment] img`);
        await chips.first().waitFor();
        expect(await chips.count()).toBe(1);
        expect(await page.locator(".acpmux-attachments .acpmux-attachment-image").count()).toBe(0);
        expect((await promptText(page)).trim()).toBe("see");
        await page.close();
      });

      test("a paste into another text field stays in that field", async () => {
        const page = await chat(browsers.get(name)!);
        await page.evaluate(() => {
          const other = document.createElement("input");
          other.id = "other-field";
          document.body.append(other);
          other.focus();
        });
        await page.keyboard.press("Meta+v");
        expect(await page.evaluate(() => document.activeElement?.id)).toBe("other-field");
        // Not cancelled: the field's own paste puts the text in it.
        expect(await paste(page, { plain: "only here" })).toBe(false);
        expect(await page.evaluate(() => document.activeElement?.id)).toBe("other-field");
        expect(await promptText(page)).toBe("");
        await page.close();
      });
    });
});
