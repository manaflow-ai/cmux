// A chat's draft and its caret are back in the first frame the chat shows: switching back to a chat
// with a draft, and after the page reloads. Leo, 2026-11-22: "when im pasting attachments or
// whatever, there's a breif moment where i see the caret at the beginning of the composer after the
// preview for the attachment has already shown up, and then it doesn't follow as fast, it follows
// with a delay. we can't have that. idk if there are other places where our caret/typing/perciee is
// lagging liek that... maybe more".
//
// The real pane on the mock daemon (test/latency/flows.html: the production App, direct client and
// chat.select path). Its daemon keeps no drafts (`_acpmux/draft_get` answers {}), so the page's
// `chat.readDraft` / `chat.writeDraft` are wrapped to answer from a store kept in sessionStorage
// (it outlives a reload), after the real round trip to the mock daemon: acpmux as the app has it.
//
// Every painted frame after the input (the switch's `selectSession`, or the reload's navigation)
// records which chat the transcript shows, the prompt's text, the caret's place in it and the
// caret's boxes (support/caretFrames.ts). A frame is wrong when it shows the chat (or, on a reload,
// the prompt) without the draft as typed or with the caret anywhere but where it was kept. One
// `CARET_FRAMES` JSON line per case and engine; `CMUX_CARET_REPORT_ONLY=1` prints without failing.
// cmux-web-test-timeout: 900
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { FRAME_MS, installCaretTrace, judgeCaret, type CaretBox, type CaretTrace } from "./support/caretFrames";

type DraftFrame = {
  at: number;
  exists: boolean;
  focused: boolean;
  text: string | null;
  caret: number | null;
  chat: string | null;
  shown: CaretBox | null;
  truth: CaretBox | null;
};

declare global {
  interface Window {
    cmuxDraftFrames?: {
      start(): void;
      stop(): { frames: DraftFrame[]; final: DraftFrame };
      read(): DraftFrame;
    };
    __latencyFlows?: { sessionId: string; restoreChat(): void; openOtherChat(): void };
    cmuxAcpmuxDebug?: { chatState(): { sessionId?: string } };
    cmuxWebSwap?: { hold(): string | null };
  }
}

/** The page side, as an init script: a store of acpmux drafts that outlives a reload, and a reader of
 *  each painted frame's prompt. Closes over nothing. */
function defineDraftFrames() {
  const FIELD = ".acpmux-composer-prompt .acpmux-md";
  const STORE = "cmux.test.daemonDrafts";
  const store = (): Record<string, string> => JSON.parse(sessionStorage.getItem(STORE) ?? "{}");
  type Action = (params: Record<string, unknown>) => Promise<unknown>;
  const wrap = (actions: Record<string, Action> | undefined) =>
    actions &&
    new Proxy(actions, {
      get(target, key, receiver) {
        const real = Reflect.get(target, key, receiver) as Action | undefined;
        if (key === "chat.readDraft" && real)
          return async (params: Record<string, unknown>) => {
            await real(params);
            return { draft: store()[String(params.sessionId)] };
          };
        if (key === "chat.writeDraft" && real)
          return async (params: Record<string, unknown>) => {
            await real(params);
            const next = store();
            if (params.text) next[String(params.sessionId)] = String(params.text);
            else delete next[String(params.sessionId)];
            sessionStorage.setItem(STORE, JSON.stringify(next));
            return {};
          };
        return real;
      },
    });
  let actions: Record<string, Action> | undefined;
  Object.defineProperty(window, "cmuxAcpmuxActions", {
    configurable: true,
    get: () => actions,
    set: (value) => {
      actions = wrap(value);
    },
  });
  const read = (): DraftFrame => {
    const at = performance.now();
    const editor = document.querySelector(FIELD);
    const chat = document.querySelector(".acpmux-scroll .cv-user__bubble")?.textContent?.trim() ?? null;
    const caretRead = window.cmuxCaretTrace?.read(FIELD);
    if (!editor) return { at, exists: false, focused: false, text: null, caret: null, chat, shown: null, truth: null };
    const selection = document.getSelection();
    let caret: number | null = null;
    if (selection?.rangeCount && selection.isCollapsed && editor.contains(selection.anchorNode)) {
      const before = document.createRange();
      before.selectNodeContents(editor);
      before.setEnd(selection.anchorNode!, selection.anchorOffset);
      caret = before.toString().length;
    }
    const focused = editor === document.activeElement || editor.contains(document.activeElement);
    return {
      at,
      exists: true,
      focused,
      text: editor.textContent ?? "",
      caret,
      chat,
      shown: caretRead?.shown ?? null,
      truth: caretRead?.truth ?? null,
    };
  };
  let frames: DraftFrame[] = [];
  let stop: (() => void) | undefined;
  const start = () => {
    stop?.();
    frames = [];
    stop = window.cmuxAfterPaint((frame) => {
      frames.push({ ...read(), at: frame });
    });
  };
  window.cmuxDraftFrames = {
    start,
    stop() {
      stop?.();
      stop = undefined;
      return { frames, final: read() };
    },
    read,
  };
  // A reload's trace starts with the document: its first frame is the page's first paint.
  if (sessionStorage.getItem("cmux.test.traceOnLoad") === "1") {
    sessionStorage.removeItem("cmux.test.traceOnLoad");
    start();
  }
}

await requireBrowserLane("composer-caret-frames-drafts.browser.test.ts", async () => {
  setDefaultTimeout(900_000);
  const FIELD = ".acpmux-composer-prompt .acpmux-md";
  const DRAFT = "Compare this with the previous result.";
  const KEPT = "Compare this".length;
  const reportOnly = process.env.CMUX_CARET_REPORT_ONLY === "1";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/latency/flows.html");
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const)
      browsers.set(name, await engine.launch({ headless: true }));
  }, 400_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const ready = (page: Page) =>
    page.waitForFunction(() => document.documentElement.dataset.latencyFlowsReady === "true", undefined, {
      timeout: 200_000,
    });
  const quietFrames = async (page: Page, frames = 20) => {
    for (let frame = 0; frame < frames; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };
  const bubble = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-scroll .cv-user__bubble")?.textContent?.trim() ?? null);

  /** The pane on chat A, its prompt holding DRAFT as typed, the caret KEPT characters in. */
  async function stage(engine: string): Promise<{ page: Page; chatA: string; chatB: string }> {
    const context = await browsers.get(engine)!.newContext({ viewport: { width: 1100, height: 800 } });
    const page = await context.newPage();
    page.on("pageerror", (error) => console.warn(`drafts caret page error: ${error.message}`));
    await installCaretTrace(page);
    await page.addInitScript(defineDraftFrames);
    await page.goto(`${base}/test/latency/flows.html`);
    await ready(page);
    await page.waitForSelector(`${FIELD}[contenteditable='true']`);
    // The chat's draft read answers before anything is typed (the prompt is hydrated).
    await quietFrames(page, 30);
    await page.click(FIELD);
    await page.keyboard.type(DRAFT);
    await quietFrames(page, 10);
    await page.evaluate((at) => {
      const field = document.querySelector(".acpmux-composer-prompt") as unknown as {
        acpmuxMarkdownField?: { setCaret(at: number): void; focus(): void };
      };
      field.acpmuxMarkdownField!.focus();
      field.acpmuxMarkdownField!.setCaret(at);
    }, KEPT);
    // Typing's draft write lands (the PR 49439 pause is 400 ms; wait past it).
    await page.waitForTimeout(1200);
    await quietFrames(page, 10);
    const chatA = (await bubble(page))!;
    const before = await page.evaluate(() => window.cmuxDraftFrames!.read());
    if (before.text !== DRAFT || before.caret !== KEPT)
      console.warn(`drafts caret: staged prompt is ${JSON.stringify(before)}`);
    // The other chat, to come back from.
    await page.evaluate(() => window.__latencyFlows!.openOtherChat());
    await page.waitForFunction(() => window.cmuxAcpmuxDebug!.chatState().sessionId === "mock-ci-cache");
    await page.waitForFunction(
      (a) => {
        const text = document.querySelector(".acpmux-scroll .cv-user__bubble")?.textContent?.trim();
        return Boolean(text) && text !== a;
      },
      chatA,
      { timeout: 30_000 },
    );
    await quietFrames(page, 20);
    const chatB = (await bubble(page))!;
    return { page, chatA, chatB };
  }

  /** What the frames say: wrong frames (the chat or prompt shown without the draft and caret where
   *  they were) and the times from the input to the chat and to the draft with its caret. */
  function judge(frames: DraftFrame[], inputAt: number, shows: (frame: DraftFrame) => boolean, needCaret: boolean) {
    const right = (frame: DraftFrame) => frame.text === DRAFT && (!needCaret || frame.caret === KEPT);
    const after = frames.filter((frame) => frame.at >= inputAt - FRAME_MS);
    const showing = after.filter(shows);
    const wrong = showing.filter((frame) => !right(frame));
    let settled = after.length;
    for (let index = after.length - 1; index >= 0; index--) {
      if (!right(after[index]!) || !shows(after[index]!)) break;
      settled = index;
    }
    const first = showing[0];
    const at = after[settled];
    const ms = (frame: DraftFrame | undefined) => (frame ? Math.round((frame.at - inputAt) * 10) / 10 : null);
    return {
      wrongFrames: wrong.length,
      shownMs: ms(first),
      draftCaretMs: ms(at),
      lagBehindShownMs: first && at ? Math.round((at.at - first.at) * 10) / 10 : null,
      firstWrong: wrong.slice(0, 4).map((frame) => ({
        afterInputMs: Math.round((frame.at - inputAt) * 10) / 10,
        text: frame.text,
        caret: frame.caret,
        focused: frame.focused,
      })),
    };
  }

  const report = (engine: string, name: string, values: Record<string, unknown>) =>
    console.log(`CARET_FRAMES ${JSON.stringify({ engine, case: name, ...values })}`);

  type Case = { name: string; run(engine: string): Promise<Record<string, unknown> & { wrongFrames: number }> };
  const CASES: Case[] = [
    {
      name: "switch back to a chat with a draft, caret mid text",
      async run(engine) {
        const { page, chatA } = await stage(engine);
        try {
          const inputAt = await page.evaluate(() => {
            window.cmuxCaretTrace!.start(".acpmux-composer-prompt .acpmux-md");
            window.cmuxDraftFrames!.start();
            const at = performance.now();
            window.cmuxCaretTrace!.input();
            window.__latencyFlows!.restoreChat();
            return at;
          });
          await page
            .waitForFunction(
              ({ a, draft }) =>
                document.querySelector(".acpmux-scroll .cv-user__bubble")?.textContent?.trim() === a &&
                document.querySelector(".acpmux-composer-prompt .acpmux-md")?.textContent === draft,
              { a: chatA, draft: DRAFT },
              { timeout: 20_000 },
            )
            .catch(() => {});
          await quietFrames(page, 30);
          const { frames, final } = await page.evaluate(() => window.cmuxDraftFrames!.stop());
          const caretTrace = (await page.evaluate(() => window.cmuxCaretTrace!.stop())) as CaretTrace;
          const verdict = judge(frames, inputAt, (frame) => frame.chat === chatA, true);
          return {
            ...verdict,
            caretBoxWrong: judgeCaret(caretTrace).wrongFrames.length,
            frames: frames.length,
            final: { text: final.text, caret: final.caret, focused: final.focused, kept: KEPT },
          };
        } finally {
          await page.context().close();
        }
      },
    },
    ...(["web swap", "plain", "acpmux only"] as const).map((kind) => ({
      name: `reload (${kind}), caret mid text`,
      async run(engine: string) {
        const { page, chatA } = await stage(engine);
        try {
          await page.evaluate(() => window.__latencyFlows!.restoreChat());
          await page.waitForFunction(
            ({ a, draft }) =>
              document.querySelector(".acpmux-scroll .cv-user__bubble")?.textContent?.trim() === a &&
              document.querySelector(".acpmux-composer-prompt .acpmux-md")?.textContent === draft,
            { a: chatA, draft: DRAFT },
            { timeout: 20_000 },
          );
          await quietFrames(page, 10);
          await page.evaluate((at) => {
            const field = document.querySelector(".acpmux-composer-prompt") as unknown as {
              acpmuxMarkdownField?: { setCaret(at: number): void; focus(): void };
            };
            field.acpmuxMarkdownField!.focus();
            field.acpmuxMarkdownField!.setCaret(at);
          }, KEPT);
          await page.waitForTimeout(600);
          await quietFrames(page, 5);
          const held = await page.evaluate((kind) => {
            sessionStorage.setItem("cmux.test.traceOnLoad", "1");
            // acpmux holds the draft; this page's remount cache does not (another window, a cleared store).
            if (kind === "acpmux only")
              for (const key of Object.keys(localStorage))
                if (key.startsWith("cmux.acpmux.composer-draft.")) localStorage.removeItem(key);
            // The host's ask before a web update reloads the page: it stashes the focus owner.
            return kind === "plain" ? "(not asked)" : (window.cmuxWebSwap?.hold() ?? null);
          }, kind);
          const stored = await page.evaluate(() => sessionStorage.getItem("cmux.test.daemonDrafts"));
          await page.reload({ waitUntil: "commit" });
          await ready(page);
          await page
            .waitForFunction(
              (draft) => document.querySelector(".acpmux-composer-prompt .acpmux-md")?.textContent === draft,
              DRAFT,
              { timeout: 20_000 },
            )
            .catch(() => {});
          await quietFrames(page, 30);
          const { frames, final } = await page.evaluate(() => window.cmuxDraftFrames!.stop());
          // The reload's input is its navigation: this document's time origin, 0.
          // Wrong from the first frame the chat shows (a New Tab or loading page before it is not it).
          const verdict = judge(frames, 0, (frame) => frame.exists && frame.chat === chatA, true);
          const text = judge(frames, 0, (frame) => frame.exists && frame.chat === chatA, false);
          return {
            ...verdict,
            draftTextMs: text.draftCaretMs,
            swapHold: held,
            acpmuxHeld: stored?.includes("previous result") ?? false,
            firstPromptMs: frames.find((frame) => frame.exists)?.at ?? null,
            firstPromptText: frames.find((frame) => frame.exists)?.text ?? null,
            frames: frames.length,
            final: { text: final.text, caret: final.caret, focused: final.focused, kept: KEPT },
          };
        } finally {
          await page.context().close();
        }
      },
    })),
  ];

  for (const engine of ["chromium", "webkit"])
    for (const each of CASES)
      test(`${engine}: ${each.name}: the draft and caret are there in the first frame`, async () => {
        const values = await each.run(engine);
        report(engine, each.name, values);
        if (reportOnly) return;
        expect(values.wrongFrames).toBe(0);
      });
});
