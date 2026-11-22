// l10n-allow-file: typed test keys, not shipped UI.
// Key to caret in the agent composer's shell mode (`!`, Composer.tsx `shellInput`, a <textarea>): the
// frame a key, a paste or Esc lands in shows the field with its new text and the caret where it ends,
// and no later frame moves it. Leo, 2026-11-22: "when im pasting attachments or whatever, there's a
// breif moment where i see the caret at the beginning of the composer after the preview for the
// attachment has already shown up, and then it doesn't follow as fast, it follows with a delay. we
// can't have that. idk if there are other places where our caret/typing/perciee is lagging liek
// that... maybe more".
//
// A census row, not a gate: the real pane (`?mock`) as it ships (vite.config.acpmux-pane.mjs,
// production React), Chromium and WebKit, real keys. After every painted frame (paintedFrames.ts) it
// reads the shell field (mounted, focused, value, selection) or, after Esc, the prompt (focused, the
// selection at the end of its text). Per case it prints one `SHELL_CARET` JSON line: input to the
// first frame from which the field stays as it ends (p50/p95/max over the keys), and the frames in
// between that showed it out of place. A native <textarea> draws its caret at its selection in the
// frame that paints the selection, so focus plus selection is the caret here.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-shell-caret-frames.browser.test.ts
// cmux-web-test-timeout: 900
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import type { ShellFrame, ShellTrace } from "./support/caretFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-shell-caret-frames.browser.test.ts", async () => {
  const FRAME_MS = 1000 / 60;

  /** The page side; closes over nothing. */
  function defineShellTrace() {
    if (window.cmuxShellTrace) return;
    const PROMPT_SELECTOR =
      ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
    const caretAtEnd = (prompt: Element | null) => {
      const selection = document.getSelection();
      if (!prompt || !selection?.rangeCount || !selection.isCollapsed || !prompt.contains(selection.anchorNode))
        return false;
      const end = document.createRange();
      end.selectNodeContents(prompt);
      end.collapse(false);
      return (
        selection.getRangeAt(0).compareBoundaryPoints(Range.START_TO_START, end) === 0 ||
        // The same place by text: everything before the caret is the whole text.
        (() => {
          const before = document.createRange();
          before.selectNodeContents(prompt);
          before.setEnd(selection.anchorNode!, selection.anchorOffset);
          return before.toString().length === (prompt.textContent ?? "").length;
        })()
      );
    };
    const read = (): ShellFrame => {
      const field = document.querySelector<HTMLTextAreaElement>(".acpmux-shell-field");
      const prompt = document.querySelector(PROMPT_SELECTOR);
      const active = document.activeElement;
      return {
        at: performance.now(),
        readAt: performance.now(),
        mounted: Boolean(field),
        focused: Boolean(field) && active === field,
        value: field?.value ?? "",
        start: field?.selectionStart ?? -1,
        end: field?.selectionEnd ?? -1,
        promptFocused: Boolean(prompt) && (prompt === active || Boolean(prompt?.contains(active))),
        promptText: (prompt?.textContent ?? "").trim(),
        promptCaretAtEnd: caretAtEnd(prompt),
      };
    };
    let frames: ShellFrame[] = [];
    let inputAt = 0;
    let stop: (() => void) | undefined;
    const mark = (event: Event) => {
      if (!inputAt) inputAt = event.timeStamp || performance.now();
    };
    const kinds = ["keydown", "beforeinput", "paste"];
    window.cmuxShellTrace = {
      start() {
        stop?.();
        frames = [];
        inputAt = 0;
        for (const kind of kinds) addEventListener(kind, mark, { capture: true });
        stop = window.cmuxAfterPaint((frame) => {
          if (!inputAt) return;
          frames.push({ ...read(), at: frame });
        });
      },
      stop() {
        stop?.();
        stop = undefined;
        for (const kind of kinds) removeEventListener(kind, mark, { capture: true });
        return { inputAt, frames, final: read() };
      },
      read,
    };
  }

  /** What a frame shows, for comparing it with the final one. */
  const look = (frame: ShellFrame) =>
    frame.mounted
      ? `shell:${frame.focused}:${frame.value}:${frame.start}:${frame.end}`
      : `prompt:${frame.promptFocused}:${frame.promptText}:${frame.promptCaretAtEnd}`;

  /** Input to the first frame from which the field stays as it ends, and the frames before it. */
  function judge(trace: ShellTrace) {
    const after = trace.frames.filter((frame) => frame.at >= trace.inputAt - FRAME_MS);
    const want = look(trace.final);
    let settled = after.length;
    for (let index = after.length - 1; index >= 0; index--) {
      if (look(after[index]!) !== want) break;
      settled = index;
    }
    const frame = after[settled];
    return {
      inputToCaretMs: frame ? Math.max(0, frame.at - trace.inputAt) : null,
      inputToReadMs: frame ? Math.max(0, frame.readAt - trace.inputAt) : null,
      framesToSettle: settled,
      before: after
        .slice(0, settled)
        .map((each) => ({ afterInputMs: Math.round((each.at - trace.inputAt) * 10) / 10, look: look(each) })),
      final: want,
    };
  }

  const quantile = (values: number[], q: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    if (sorted.length === 0) return null;
    return Math.round(sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * q))]! * 10) / 10;
  };

  setDefaultTimeout(600_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  const SHELL = ".acpmux-shell-field";
  const KEYS = 20;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "terminal-caret-frames-shell-"));
  let statics: ReturnType<typeof Bun.serve> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const)
      browsers.set(name, await engine.launch({ headless: true }));
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await statics?.stop(true);
    fs.rmSync(out, { recursive: true, force: true });
  });

  const quiet = async (page: Page, frames = 12) => {
    for (let frame = 0; frame < frames; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };

  /** The pane with `rows` seeded rows, the prompt focused and empty. */
  async function stage(engine: string, rows: number): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 1100, height: 820 } });
    await page.goto(`http://127.0.0.1:${statics!.port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    if (rows > 0)
      await page.evaluate((count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }), rows);
    await installPaintedFrames(page);
    await page.evaluate(defineShellTrace);
    const prompt = page.locator(PROMPT).first();
    await prompt.waitFor({ timeout: 30_000 });
    await prompt.click();
    await quiet(page);
    return page;
  }

  /** Into shell mode with `typed` in the field, the caret at its end. */
  async function intoShell(page: Page, typed: string) {
    await page.keyboard.press("!");
    await page.waitForSelector(SHELL, { timeout: 10_000 });
    if (typed) await page.keyboard.type(typed);
    await page.waitForFunction(
      ([selector, want]) => (document.querySelector(selector!) as HTMLTextAreaElement | null)?.value === want,
      [SHELL, typed] as const,
    );
    await quiet(page);
  }

  async function traced(page: Page, act: () => Promise<void>, frames = 20) {
    await page.evaluate(() => window.cmuxShellTrace!.start());
    await act();
    await quiet(page, frames);
    return judge((await page.evaluate(() => window.cmuxShellTrace!.stop())) as ShellTrace);
  }

  type Sample = ReturnType<typeof judge>;
  type Case = { name: string; repeat: number; run(page: Page): Promise<Sample[]>; expect(sample: Sample): void };
  const CASES: Case[] = [
    {
      name: "! enters shell mode (empty prompt)",
      repeat: 1,
      async run(page) {
        return [await traced(page, () => page.keyboard.press("!"))];
      },
      expect: (sample) => expect(sample.final).toBe("shell:true::0:0"),
    },
    {
      name: "type a character at the end",
      repeat: KEYS,
      async run(page) {
        await intoShell(page, "ls -la");
        const samples: Sample[] = [];
        for (let key = 0; key < KEYS; key++) samples.push(await traced(page, () => page.keyboard.press("x"), 6));
        return samples;
      },
      expect: (sample) => expect(sample.final).toMatch(/^shell:true:ls -lax+:(\d+):\1$/),
    },
    {
      name: "type a character mid text",
      repeat: KEYS,
      async run(page) {
        await intoShell(page, "ls -la");
        await page.evaluate((selector) => {
          const field = document.querySelector(selector) as HTMLTextAreaElement;
          field.setSelectionRange(2, 2);
        }, SHELL);
        await quiet(page);
        const samples: Sample[] = [];
        for (let key = 0; key < KEYS; key++) samples.push(await traced(page, () => page.keyboard.press("y"), 6));
        return samples;
      },
      expect: (sample) => expect(sample.final).toMatch(/^shell:true:lsy+ -la:(\d+):\1$/),
    },
    {
      name: "paste text in the field",
      repeat: 1,
      async run(page) {
        await intoShell(page, "ls");
        return [await traced(page, () => page.keyboard.insertText(" -la /tmp"))];
      },
      expect: (sample) => expect(sample.final).toBe("shell:true:ls -la /tmp:11:11"),
    },
    {
      name: "paste with the keyboard outside the field (paste anywhere)",
      repeat: 1,
      async run(page) {
        await intoShell(page, "ls");
        await page.evaluate((selector) => (document.querySelector(selector) as HTMLElement).blur(), SHELL);
        await quiet(page);
        return [
          await traced(page, () =>
            page.evaluate(() => {
              const transfer = new DataTransfer();
              transfer.setData("text/plain", " -la");
              document.body.dispatchEvent(
                new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }),
              );
            }),
          ),
        ];
      },
      expect: (sample) => expect(sample.final).toBe("shell:true:ls -la:6:6"),
    },
    {
      name: "!ls inserted at once (a pasted command)",
      repeat: 1,
      async run(page) {
        return [await traced(page, () => page.keyboard.insertText("!ls"))];
      },
      expect: (sample) => expect(sample.final).toBe("shell:true:ls:2:2"),
    },
    {
      // Red on 45dbc9020256 (fleet run 44998498055, both engines): exitShell (Composer.tsx:1899) calls
      // field.current.focus() while the prompt is still `is-hidden` (display:none, Composer.tsx:2916,
      // composerStates.css:636), so the focus is a no-op, the textarea unmounts and the keyboard falls
      // to <body>: no caret anywhere after Esc. runShell (Composer.tsx:1907) does the same after Enter.
      name: "Esc leaves shell mode, text to the prompt",
      repeat: 1,
      async run(page) {
        await intoShell(page, "ls -la");
        return [await traced(page, () => page.keyboard.press("Escape"), 30)];
      },
      expect: (sample) => expect(sample.final).toBe("prompt:true:ls -la:true"),
    },
  ];

  for (const engine of ["chromium", "webkit"])
    for (const rows of [0, 1500])
      for (const each of CASES)
        test(`${engine}, ${rows} rows: ${each.name}: the caret is in place in the input's frame`, async () => {
          const page = await stage(engine, rows);
          try {
            const samples = await each.run(page);
            const ms = samples.map((sample) => sample.inputToCaretMs ?? Number.NaN).filter(Number.isFinite);
            const readMs = samples.map((sample) => sample.inputToReadMs ?? Number.NaN).filter(Number.isFinite);
            const late = samples.filter((sample) => sample.framesToSettle > 1);
            console.log(
              `SHELL_CARET ${JSON.stringify({
                engine,
                rows,
                case: each.name,
                samples: samples.length,
                inputToCaretMs: { p50: quantile(ms, 0.5), p95: quantile(ms, 0.95), max: quantile(ms, 1) },
                inputToPaintedReadMs: {
                  p50: quantile(readMs, 0.5),
                  p95: quantile(readMs, 0.95),
                  max: quantile(readMs, 1),
                },
                framesToSettle: { max: Math.max(...samples.map((sample) => sample.framesToSettle)) },
                lateSamples: late.length,
                firstLate: late
                  .slice(0, 2)
                  .map((sample) => ({ before: sample.before.slice(0, 4), final: sample.final })),
                final: samples[samples.length - 1]?.final,
              })}`,
            );
            expect(samples.length).toBe(each.repeat);
            for (const sample of samples) each.expect(sample);
          } finally {
            await page.close();
          }
        });
});
