// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// A word put into the composer, by a key or as dictation puts it in, draws the composer and its box and
// nothing else under it: no render of another part of it, and no attribute written on any element of it
// but the prompt's own text (Leo, 2026-11-08, of the composer while dictating: "there was like a partial
// focus or something of the sort"; typing p95 under load, chat-instant-under-load).
//
// On the base it was measured on, each word rendered the composer, its box and its queue, and wrote 13
// attributes on elements whose props had not changed: React re-writes an input's `name` and `type` on
// every commit of it, and the composer's hidden file inputs and its look switch's radios were committed
// on every key, because the React Compiler left the composer and its box uncompiled (a `try` without a
// `catch`, `??=`, refs written during render). Each word re-created every child's props.
//
// The page is the pane's dev entry with the in-page mock daemon and a short synthetic chat. Real
// Chromium and WebKit; CI fails the file when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

type Writes = { total: number; kinds: Record<string, number> };

await requireBrowserLane("composer-word-writes-browser.test.ts", async () => {
  const COMPOSER = "form.acpmux-composer";
  const WORDS = 20;
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  const twoFrames = () =>
    new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));

  async function openPane(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.seedRows(60));
    await page.locator(COMPOSER_EDITOR).click();
    await page.keyboard.type("a draft");
    await page.waitForFunction(
      (editor) => document.querySelector(editor)?.textContent?.includes("a draft"),
      COMPOSER_EDITOR,
    );
    await page.evaluate(twoFrames);
    return page;
  }

  /// Watches the composer's attributes outside the prompt's text until the returned stop.
  async function watchWrites(page: Page) {
    await page.evaluate(
      ({ composer, editor }) => {
        const form = document.querySelector<HTMLElement>(composer)!;
        const prompt = form.querySelector<HTMLElement>(editor)!;
        const writes: Writes = { total: 0, kinds: {} };
        const observer = new MutationObserver((records) => {
          for (const record of records) {
            if (prompt.contains(record.target)) continue;
            const node = record.target as Element;
            const kind = `${node.nodeName.toLowerCase()}.${String(node.getAttribute?.("class") ?? "").split(" ")[0]} ${record.attributeName}`;
            writes.total += 1;
            writes.kinds[kind] = (writes.kinds[kind] ?? 0) + 1;
          }
        });
        observer.observe(form, { subtree: true, attributes: true });
        (window as any).__stopWrites = () => {
          observer.disconnect();
          return writes;
        };
      },
      { composer: COMPOSER, editor: COMPOSER_EDITOR },
    );
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`composer-word-writes (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      for (const way of ["keys", "dictation"] as const)
        test(`a word ${way === "keys" ? "typed" : "dictated"} into the composer draws its box and writes nothing else`, async () => {
          const page = await openPane(browser!);
          await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
          await watchWrites(page);
          for (let word = 0; word < WORDS; word += 1) {
            if (way === "keys") await page.keyboard.type(` w${word}`);
            else
              await page.evaluate(
                ([editor, text]) => {
                  if (document.activeElement !== document.querySelector(editor)) return;
                  document.execCommand("insertText", false, text);
                },
                [COMPOSER_EDITOR, ` w${word}`] as const,
              );
            await page.evaluate(twoFrames);
          }
          await page.waitForFunction(([editor, last]) => document.querySelector(editor)?.textContent?.includes(last), [
            COMPOSER_EDITOR,
            `w${WORDS - 1}`,
          ] as const);
          await page.evaluate(twoFrames);
          const writes = (await page.evaluate(() => (window as any).__stopWrites())) as Writes;
          const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<
            string,
            number
          >;
          const text = await page.locator(COMPOSER_EDITOR).innerText();
          await page.close();
          // A typed word is three keys (a space and two characters); a dictated one, one insert.
          const edits = way === "keys" ? WORDS * 3 : WORDS;
          const composerParts = Object.fromEntries(
            Object.entries(renders).filter(([part]) => part === "composer" || part.startsWith("composer:")),
          );
          const per = (count: number | undefined) => Math.round(((count ?? 0) / edits) * 100) / 100;
          console.log(
            `COMPOSER-WORD-WRITES ${JSON.stringify({
              engine: name,
              way,
              edits,
              composer_per_edit: per(renders.composer),
              box_per_edit: per(renders["composer:box"]),
              parts: composerParts,
              attribute_writes: writes.total,
              writes_per_edit: per(writes.total),
              kinds: writes.kinds,
            })}`,
          );
          expect(text, "every word reached the prompt").toContain(`w${WORDS - 1}`);
          expect(writes.kinds, "attributes written outside the prompt's text").toEqual({});
          // The composer holds the text and the box draws it. Another part may draw once in the window (the
          // first edit changes what the send slot offers), never once per word.
          for (const [part, count] of Object.entries(composerParts))
            if (part !== "composer" && part !== "composer:box")
              expect(count, `${part} renders over ${edits} edits`).toBeLessThanOrEqual(1);
          // A key that ends a word (a space) can draw the composer once more: its word count changes.
          expect(renders.composer ?? 0, "composer renders").toBeLessThanOrEqual(Math.ceil(edits * 1.5));
          expect(renders["composer:box"] ?? 0, "box renders").toBeLessThanOrEqual(Math.ceil(edits * 1.5));
        });
    });
  }
});
