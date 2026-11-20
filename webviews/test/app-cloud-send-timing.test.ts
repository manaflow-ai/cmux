// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts and dictated words, not shipped UI.
// Two timings the Cloud send's move into its own hook (acpmux/useCloudSend.ts) changed, pinned to what the
// pane did before the move (b4933ba8547), in real Chromium and WebKit.
//
// `cloudStartingNow`, which dictation's `attach` reads (App.tsx `useDictation(..., { attach })`), was written
// during the pane's render and is now written in an insertion effect. Both land in the same synchronous
// render and commit of the Send's update, before any other task runs, so `attach` sees the same value either
// way. The host hands dictation's last update to the page in a task of its own (`cmuxAcpmuxBridge.dictation`,
// pageHost.ts `dictation`), so the earliest a real recording can arrive after a Send is the next task: by
// then the start is out, and the recording is left out of the composer (the words still land). The Send's
// own task and its microtasks, which no host message reaches, show the boundary: before React renders the
// Send's update, `attach` reads no start (base did too: its ref was only written in render), and from the
// microtask after the Send it reads the start.
//
// `setUpCloudNow`, the model picker's Connect row's way to Set up Cloud, starts as a no-op until the hook's
// first passive effect (base started with the first render's `setUpCloud`, which was a no-op as well: no
// Cloud start had failed). The row is offered only for a failed start that names a set up, so it is absent
// before any start, and its Connect, once offered, sets Cloud up (`cloud.setUp`). The row is in the full
// picker (Cmd-Ctrl-M twice); the compact columns menu a click on the chip opens shows none.
//
// The page is the pane's dev entry with the in-page mock daemon; a stand-in for the app's bridge answers the
// host's side. acpmux's mock reports no audio capability, so the page reads the mock's own new chat as a
// Codex session that takes audio (ACP `promptCapabilities.audio`), as acpmux reports Codex 0.145+.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

type Call = [string, Record<string, unknown> | undefined];

await requireBrowserLane("app-cloud-send-timing.test.ts", async () => {
  const PROMPT = "Run the sidebar tests and fix what fails";
  const WORDS = "spoken while it starts";
  /// The recording's chip name (strings.json `dictation.recording`).
  const RECORDING = "Voice recording";
  const CARD = ".acpmux-cloud-start";
  const SEND = ".acpmux-send.acpmux-send-ready";
  const BOX = ".acpmux-composer-box";
  const FULL_PICKER_MODELS = ".acpmux-mp-models";
  const CONNECT_ROW = ".acpmux-connect-claude-row";
  const CONNECT = ".acpmux-connect-claude-row-button";

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

  /// The pane with the stand-in bridge. `startAnswer`: how `cloud.startChat` answers (`hold` keeps it out).
  async function openPane(browser: Browser, startAnswer: "hold" | "setUp", hearsAudio: boolean): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(
      ([answer, audio]) => {
        const calls: [string, Record<string, unknown> | undefined][] = [];
        const ok = (value: unknown) => Promise.resolve({ ok: true, value });
        if (audio) {
          // The mock's new chats as acpmux reports a Codex session that takes audio.
          const parse = JSON.parse;
          const hears = (value: unknown): void => {
            if (!value || typeof value !== "object") return;
            if (Array.isArray(value)) return value.forEach(hears);
            const record = value as Record<string, unknown>;
            if (
              typeof record.sessionId === "string" &&
              record.sessionId.startsWith("mock-session-") &&
              typeof record.harness === "string"
            )
              record.agentCapabilities = { promptCapabilities: { image: true, audio: true } };
            for (const key of Object.keys(record)) hears(record[key]);
          };
          JSON.parse = function (text: string, reviver?: (this: unknown, key: string, value: unknown) => unknown) {
            const value: unknown = parse.call(JSON, text, reviver);
            if (typeof text === "string" && text.includes("mock-session-")) hears(value);
            return value;
          } as typeof JSON.parse;
        }
        Object.assign(window, {
          __calls: calls,
          webkit: {
            messageHandlers: {
              agentSession: {
                standIn: true,
                postMessage: (message: { method?: string; params?: Record<string, unknown> }) => {
                  calls.push([String(message.method), message.params]);
                  switch (message.method) {
                    case "ready":
                      return ok({
                        protocolVersion: 1,
                        transport: "mock",
                        machineName: "This Mac",
                        newSession: true,
                        sandboxState: true,
                        cwd: "~/code/cmux",
                      });
                    case "transport.gesture":
                      return ok({ ticket: "timing-test" });
                    case "cloud.startChat":
                      // Nothing serves Claude in Cloud yet: the host asks for a set up (CloudSetup.swift).
                      if (answer === "setUp")
                        return Promise.resolve({
                          ok: false,
                          error: {
                            code: "cloud_setup_required",
                            userMessage: "Set up Cloud to run Claude Code.",
                            details: { family: "claude" },
                          },
                        });
                      return new Promise(() => undefined);
                    case "cloud.setUp":
                      return new Promise(() => undefined);
                    default:
                      return ok(null);
                  }
                },
              },
            },
          },
        });
      },
      [startAnswer, hearsAudio] as const,
    );
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    await page.locator(COMPOSER_EDITOR).waitFor({ timeout: 60_000 });
    if (hearsAudio) {
      // An empty local Codex chat, which a Cloud Send replaces; dictation keeps its recording there.
      await page.evaluate(() => (window as any).cmuxAcpmuxDebug.newChat("codex"));
      await page.waitForFunction(
        () =>
          ((window as any).__calls as Call[]).filter(([method]) => method === "dictation.audio").at(-1)?.[1]
            ?.enabled === true,
        null,
        { timeout: 30_000 },
      );
    }
    await page.waitForFunction(() => (window as any).cmuxAcpmuxDebug.runMode("cloud").runMode === "cloud", null, {
      timeout: 30_000,
    });
    await page.locator(COMPOSER_EDITOR).click();
    await page.keyboard.type(PROMPT);
    await page.waitForFunction(([editor, text]) => document.querySelector(editor)?.textContent?.includes(text), [
      COMPOSER_EDITOR,
      PROMPT,
    ] as const);
    await page.locator(SEND).waitFor();
    await page.evaluate(twoFrames);
    return page;
  }

  /// A session the host ends with its words and its recording, delivered as the host delivers each update.
  const DICTATION = [
    { state: "starting", text: "", level: 0, cancelled: false },
    { state: "listening", text: WORDS, level: 0.4, cancelled: false },
    {
      state: "idle",
      text: WORDS,
      level: 0,
      cancelled: false,
      audio: { mimeType: "audio/wav", data: "UklGRgAAAABXQVZF" },
    },
  ];

  /// Once the words are in the composer (the recording, if it went, joined it before them), what it shows.
  async function afterWords(page: Page) {
    await page.waitForFunction(([editor, words]) => document.querySelector(editor)?.textContent?.includes(words), [
      COMPOSER_EDITOR,
      WORDS,
    ] as const);
    await page.evaluate(twoFrames);
    return {
      box: await page.locator(BOX).innerText(),
      card: await page.locator(CARD).getAttribute("data-state"),
    };
  }

  /// Cmd-Ctrl-M opens the compact model menu, and again the full picker (ModelPicker.tsx), whose Claude
  /// section holds the Connect row; the compact columns menu has none.
  async function openFullPicker(page: Page) {
    await page.keyboard.press("Meta+Control+KeyM");
    await page.locator(".acpmux-cols").waitFor();
    await page.keyboard.press("Meta+Control+KeyM");
    await page.locator(FULL_PICKER_MODELS).waitFor();
    await page.evaluate(twoFrames);
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`app-cloud-send-timing (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a recording the host hands over in the task after a Cloud Send is left out: attach reads the start", async () => {
        const page = await openPane(browser!, "hold", true);
        await page.keyboard.press("Enter");
        // The host's next message: a task of its own, after the Send's.
        await page.evaluate((updates) => {
          for (const update of updates) (window as any).cmuxAcpmuxBridge.dictation(update);
        }, DICTATION);
        const shown = await afterWords(page);
        await page.close();
        expect(shown.card, "the start is out").toBe("starting");
        expect(shown.box, "the words land").toContain(WORDS);
        expect(shown.box, "no recording chip").not.toContain(RECORDING);
      });

      test("from the microtask after the Send, attach reads the start (the Send's render is in)", async () => {
        const page = await openPane(browser!, "hold", true);
        const cardThen = await page.evaluate(
          ([send, card, updates]) => {
            (document.querySelector(send) as HTMLButtonElement).click();
            return new Promise<string | null>((resolve) =>
              queueMicrotask(() => {
                const state = document.querySelector(card)?.getAttribute("data-state") ?? null;
                for (const update of updates) (window as any).cmuxAcpmuxBridge.dictation(update);
                resolve(state);
              }),
            );
          },
          [SEND, CARD, DICTATION] as const,
        );
        const shown = await afterWords(page);
        await page.close();
        expect(cardThen, "the Send's render, in before the microtask").toBe("starting");
        expect(shown.box, "the words land").toContain(WORDS);
        expect(shown.box, "no recording chip").not.toContain(RECORDING);
      });

      test("in the Send's own task, before React renders it, attach reads no start, as before the move", async () => {
        const page = await openPane(browser!, "hold", true);
        const cardThen = await page.evaluate(
          ([send, card, updates]) => {
            (document.querySelector(send) as HTMLButtonElement).click();
            const state = document.querySelector(card)?.getAttribute("data-state") ?? null;
            for (const update of updates) (window as any).cmuxAcpmuxBridge.dictation(update);
            return state;
          },
          [SEND, CARD, DICTATION] as const,
        );
        await page.waitForFunction(([box, chip]) => document.querySelector(box)?.textContent?.includes(chip), [
          BOX,
          RECORDING,
        ] as const);
        const shown = await afterWords(page);
        await page.close();
        expect(cardThen, "no render yet").toBeNull();
        expect(shown.card, "the start is out").toBe("starting");
        expect(shown.box, "the recording joined the composer").toContain(RECORDING);
      });

      test("the Connect row is offered only once a start asks for a set up, and its Connect sets Cloud up", async () => {
        const page = await openPane(browser!, "setUp", false);
        // Before any start (mount, its effects, a typed prompt): the full picker has no Connect row.
        await openFullPicker(page);
        const rowsBefore = await page.locator(CONNECT_ROW).count();
        await page.keyboard.press("Escape");
        await page.waitForFunction((models) => !document.querySelector(models), FULL_PICKER_MODELS);
        await page.locator(COMPOSER_EDITOR).click();
        await page.keyboard.press("Enter");
        await page.locator(`${CARD}[data-state='failed']`).waitFor({ timeout: 30_000 });
        await openFullPicker(page);
        await page.locator(CONNECT).click();
        await page.waitForFunction(() =>
          ((window as any).__calls as Call[]).some(([method]) => method === "cloud.setUp"),
        );
        const setUp = ((await page.evaluate(() => (window as any).__calls)) as Call[]).filter(
          ([method]) => method === "cloud.setUp",
        );
        await page.close();
        expect(rowsBefore, "Connect rows before a start").toBe(0);
        expect(setUp.length, "cloud.setUp calls").toBe(1);
        expect(setUp[0]![1], "the set up Connect asked for").toMatchObject({ action: "setUpClaude", family: "claude" });
      });
    });
  }
});
