// Leo 2026-10-22: "cmd v anywhere in chat should put it in chat" (and 2026-10-21: "pastes need to be
// able to paset even when the composer isn't litearlly focused"). #24040 sent a paste outside a
// field into a chat's composer, but the New Tab page has its own field, not the chat composer, and
// installed no such route: with the keyboard on the page's background, a row or a card, Cmd-V did
// nothing and a paste the page got went nowhere. Now the New Tab field takes it as the chat
// composer does (composer/pasteAnywhere.ts): Cmd-V moves the keyboard into the field, caret at the
// end, and a paste outside a field lands there, text after the draft and an image as a chip. Another
// text field keeps its own paste. Both New Tab designs: the one-input screen and the classic page.
//
// The real agent pane (vite.config.acpmux-pane.mjs) as a New Tab page, with a stand-in host and the
// in-page mock transport. Chromium and WebKit; CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-paste-anywhere.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-paste-anywhere.test.ts", async () => {
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
      console.warn(`new-tab-paste-anywhere: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab paste anywhere", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
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

  /// The two New Tab designs: the one-input screen (the default) and the classic page (`layout` "a").
  const designs = [
    { design: "screen", field: ".nt-field", chips: ".nt-box .acpmux-attachment-image", context: {} },
    {
      design: "classic",
      field: ".acpmux-newtab-field",
      chips: ".acpmux-newtab-box .acpmux-attachment-image",
      context: { layout: "a" },
    },
  ] as const;
  type Design = (typeof designs)[number];

  /// A New Tab page, as Cmd-T opens one, on the in-page mock daemon, with the keyboard on nothing
  /// (a press on the page's background leaves nothing focused).
  async function newTab(name: string, design: Design, draft = ""): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript((extra) => {
      const newTab = { kind: "agent", hotkeys: {}, home: "/Users/you", projects: [], ...extra };
      Object.assign(window, {
        __cmuxNewTabContext: newTab,
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
        },
      });
    }, design.context);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    const field = page.locator(design.field);
    await field.waitFor();
    if (draft) {
      await field.click();
      await page.keyboard.type(draft);
      await field.evaluate((node: HTMLInputElement) => node.setSelectionRange(0, 0));
    }
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur?.());
    expect(await inField(page, design)).toBe(false);
    return page;
  }

  const inField = (page: Page, design: Design) =>
    page.evaluate((selector) => document.activeElement?.matches(selector) === true, design.field);
  const fieldText = (page: Page, design: Design) => page.locator(design.field).inputValue();

  /// Dispatches the paste the app's Paste sends to the focused element (the page, when nothing has
  /// the keyboard), carrying `clipboard`; a PNG drawn in the page stands for a copied image.
  function paste(page: Page, clipboard: { image?: boolean; plain?: string }) {
    return page.evaluate(async ({ image, plain }) => {
      const data = new DataTransfer();
      if (image) {
        const canvas = document.createElement("canvas");
        canvas.width = 320;
        canvas.height = 200;
        const context = canvas.getContext("2d")!;
        context.fillStyle = "#3a7bd5";
        context.fillRect(0, 0, canvas.width, canvas.height);
        const blob = await new Promise<Blob>((done) => canvas.toBlob((made) => done(made!), "image/png"));
        data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      }
      if (plain) data.setData("text/plain", plain);
      const event = new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data });
      if (!event.clipboardData) Object.defineProperty(event, "clipboardData", { value: data });
      (document.activeElement ?? document.body).dispatchEvent(event);
      return event.defaultPrevented;
    }, clipboard);
  }

  /// Puts a control of `tag` in the page and gives it the keyboard.
  const focusNew = (page: Page, tag: "button" | "input", id: string) =>
    page.evaluate(
      ({ tag, id }) => {
        const element = document.createElement(tag);
        element.id = id;
        if (tag === "button") element.textContent = "a row";
        document.querySelector(".acpmux-main")!.append(element);
        element.focus();
      },
      { tag, id },
    );

  for (const [name] of engines)
    for (const design of designs)
      describe(`${name}, ${design.design}`, () => {
        test("Cmd-V with the keyboard on the page moves it into the field", async () => {
          const page = await newTab(name, design);
          await page.keyboard.press("Meta+v");
          expect(await inField(page, design)).toBe(true);
          await page.close();
        });

        test("Cmd-V on a button of the page moves the keyboard into the field", async () => {
          const page = await newTab(name, design);
          await focusNew(page, "button", "page-button");
          await page.keyboard.press("Meta+v");
          expect(await inField(page, design)).toBe(true);
          await page.close();
        });

        test("text pasted outside the field goes at the end of the draft, and typing goes on", async () => {
          const page = await newTab(name, design, "fix the");
          expect(await paste(page, { plain: " flaky retry" })).toBe(true);
          expect(await fieldText(page, design)).toBe("fix the flaky retry");
          expect(await inField(page, design)).toBe(true);
          await page.keyboard.type(" test");
          expect(await fieldText(page, design)).toBe("fix the flaky retry test");
          await page.close();
        });

        test("an image pasted outside the field is a chip in the New Tab box", async () => {
          const page = await newTab(name, design);
          expect(await paste(page, { image: true })).toBe(true);
          await page.locator(design.chips).first().waitFor();
          expect(await page.locator(design.chips).count()).toBe(1);
          expect(await fieldText(page, design)).toBe("");
          await page.close();
        });

        test("a paste into another text field stays in that field", async () => {
          const page = await newTab(name, design);
          await focusNew(page, "input", "other-field");
          await page.keyboard.press("Meta+v");
          expect(await page.evaluate(() => document.activeElement?.id)).toBe("other-field");
          expect(await paste(page, { plain: "only here" })).toBe(false);
          expect(await page.evaluate(() => document.activeElement?.id)).toBe("other-field");
          expect(await fieldText(page, design)).toBe("");
          await page.close();
        });
      });
});
