// The code editor page (src/pages/editor) with real Monaco in real engines (headless Chromium and
// WebKit from Playwright), against the webviews dev server's host (dev-server/editorHost.ts):
// - a file opens highlighted by Shiki, and an edit saves through `cmux.editor.save` (Cmd-S is the
//   dispatcher's `save` page command);
// - a save writes the file byte for byte: BOM, CRLF, LF, lone CR and a missing final newline stay;
//   a file without an edit (or with its edits undone) is never written;
// - a stale base hash is refused (the conflict banner), and Keep My Changes writes over the disk;
// - files outside the workspace roots and non-UTF-8 files open read only and never save;
// - the empty state lists recent files; the Word Wrap toggle writes the editor.* preference;
// - large files open with highlighting and the minimap off;
// - Monaco's screen reader mode works from the keyboard alone (Tab in, read lines, find).
//
// The engines come from `playwright install chromium webkit`. Where they are not installed (the
// Linux CI image), the browser cases are skipped and say so. EDITOR_SCREENSHOTS=<dir> saves
// screenshots there (editor-*.png).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("editor-page.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  const installed: [string, BrowserType][] = [];
  for (const engine of engines) {
    try {
      const browser = await engine[1].launch({ headless: true });
      await browser.close();
      installed.push(engine);
    } catch {
      // Not installed here.
    }
  }
  if (installed.length < engines.length) {
    console.warn(
      `editor-page: skipping ${engines
        .filter((engine) => !installed.includes(engine))
        .map(([name]) => name)
        .join(", ")} (run \`bunx playwright install chromium webkit\`)`,
    );
  }

  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-editor-page-")));
  const workspace = path.join(root, "workspace");
  const readOnlyRoot = path.join(root, "outside");
  const stateDir = path.join(root, "state");
  const configFile = path.join(root, "config", "cmux.json");
  for (const folder of [workspace, readOnlyRoot, stateDir, path.dirname(configFile)])
    fs.mkdirSync(folder, { recursive: true });
  // Saves happen on Cmd-S only, so every write in these tests is one the test asked for.
  fs.writeFileSync(configFile, JSON.stringify({ editor: { autoSave: "off", minimap: { enabled: true } } }));
  const shots = process.env.EDITOR_SCREENSHOTS;

  let server: ChildProcess | null = null;
  let base = "";

  beforeAll(async () => {
    if (installed.length === 0) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        CMUX_EDITOR_DEV_ROOTS: workspace,
        CMUX_EDITOR_DEV_READONLY_ROOTS: readOnlyRoot,
        CMUX_WEBVIEWS_DEV_STATE_DIR: stateDir,
        CMUX_NEXT_CONFIG_FILE: configFile,
      },
    });
    base = `http://127.0.0.1:${port}`;
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
  }, 60_000);

  afterAll(() => {
    server?.kill();
    fs.rmSync(root, { recursive: true, force: true });
  });

  let counter = 0;
  /** A new file in `folder` with exactly `bytes`. */
  function file(name: string, bytes: string | Uint8Array, folder = workspace): string {
    const target = path.join(folder, `${counter++}-${name}`);
    fs.writeFileSync(target, bytes);
    return target;
  }

  const bytesOf = (target: string) => fs.readFileSync(target);
  const utf8 = (text: string) => Buffer.from(text, "utf8");

  async function openEditor(page: Page, target: string, options: { highlighted?: boolean } = {}) {
    await page.goto(`${base}/editor?file=${encodeURIComponent(target)}`);
    await page.waitForFunction(
      () =>
        document.documentElement.dataset.cmuxEditorBoot === "ready" &&
        document.documentElement.dataset.cmuxEditorPhase === "ready" &&
        !!document.querySelector(".monaco-editor .view-line"),
      null,
      { timeout: 60_000 },
    );
    if (options.highlighted) {
      await page.waitForFunction(() => document.documentElement.dataset.cmuxEditorHighlighted === "true", null, {
        timeout: 30_000,
      });
    }
  }

  /** Puts the caret at a 1-based line and column and focuses the editor. */
  async function caret(page: Page, lineNumber: number, column: number) {
    await page.evaluate(
      ([lineNumber, column]) => {
        const editor = window.__cmuxEditor!.view()!.monacoEditor;
        editor.setPosition({ lineNumber, column });
        editor.focus();
      },
      [lineNumber, column],
    );
  }

  async function save(page: Page) {
    await page.keyboard.press("Meta+s");
    await page.waitForFunction(() => document.documentElement.dataset.cmuxEditorStatus !== "saving");
    // The status updates after the host answered; give the page a frame to settle.
    await page.waitForTimeout(100);
  }

  /** The dev host's preferences file once `check` holds for it (the write is asynchronous). */
  async function preferencesWhen(check: (preferences: Record<string, unknown>) => boolean) {
    const target = path.join(stateDir, "editor-preferences.json");
    for (let tries = 0; tries < 50; tries += 1) {
      try {
        const preferences = JSON.parse(fs.readFileSync(target, "utf8"));
        if (check(preferences)) return preferences;
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("preferences never matched");
  }

  const editorText = (page: Page) =>
    page.evaluate(() => window.__cmuxEditor!.view()!.monacoEditor.getModel()!.getValue());

  for (const [name, engine] of installed) {
    describe(`editor page (${name})`, () => {
      let browser: Browser;
      let page: Page;

      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser.close();
      });

      const fresh = async (colorScheme: "light" | "dark" = "light") => {
        await page?.close();
        page = await browser.newPage({ viewport: { width: 1000, height: 640 }, colorScheme });
        return page;
      };

      test("opens a file highlighted by Shiki, edits and saves it", async () => {
        await fresh();
        const target = file("a.ts", 'const greeting = "hello";\n// a comment\n');
        await openEditor(page, target, { highlighted: true });
        expect(await page.evaluate(() => document.documentElement.dataset.cmuxEditorLanguage)).toBe("typescript");
        // Tokens carry Shiki's colors: the string and the comment differ from plain text.
        // Monaco paints the new tokens on its next render.
        await page.waitForFunction(
          () =>
            new Set([...document.querySelectorAll(".view-line span span")].map((span) => getComputedStyle(span).color))
              .size > 2,
          null,
          { timeout: 10_000 },
        );
        await caret(page, 1, 1);
        await page.keyboard.type("export ");
        expect(await page.evaluate(() => document.documentElement.dataset.cmuxEditorStatus)).toBe("edited");
        await save(page);
        expect(bytesOf(target).toString("utf8")).toBe('export const greeting = "hello";\n// a comment\n');
        expect(await page.evaluate(() => document.documentElement.dataset.cmuxEditorStatus)).toBe("saved");
        if (shots && name === "chromium") await page.screenshot({ path: path.join(shots, "editor-light.png") });
      });

      test("a save keeps the BOM, every line ending and the missing final newline", async () => {
        await fresh();
        const original = "﻿one\r\ntwo\nthree\rfour";
        const target = file("mixed.txt", utf8(original));
        await openEditor(page, target);
        await caret(page, 2, 4);
        await page.keyboard.type("!");
        await caret(page, 3, 6);
        await page.keyboard.press("Enter");
        await page.keyboard.type("x");
        await save(page);
        expect(bytesOf(target).equals(utf8("﻿one\r\ntwo!\nthree\nx\rfour"))).toBe(true);
      });

      test("CRLF and no-final-newline files round-trip exactly", async () => {
        await fresh();
        const crlf = file("crlf.txt", utf8("a\r\nb\r\n"));
        await openEditor(page, crlf);
        await caret(page, 1, 2);
        await page.keyboard.type("!");
        await caret(page, 3, 1);
        await page.keyboard.type("c");
        await save(page);
        expect(bytesOf(crlf).equals(utf8("a!\r\nb\r\nc"))).toBe(true);
        const bare = file("bare.txt", utf8("x\ny"));
        await openEditor(page, bare);
        await caret(page, 2, 2);
        await page.keyboard.type("z");
        await save(page);
        expect(bytesOf(bare).equals(utf8("x\nyz"))).toBe(true);
      });

      test("a file the user did not edit, or whose edits were undone, is never written", async () => {
        await fresh();
        const target = file("untouched.txt", utf8("﻿keep\r\nme\r"));
        const before = fs.statSync(target).mtimeMs;
        await openEditor(page, target);
        await save(page);
        await caret(page, 1, 1);
        await page.keyboard.type("abc");
        await page.keyboard.press("Meta+z");
        expect(await editorText(page)).toBe("keep\r\nme\r\n");
        await save(page);
        expect(fs.statSync(target).mtimeMs).toBe(before);
        expect(bytesOf(target).equals(utf8("﻿keep\r\nme\r"))).toBe(true);
      });

      test("a stale save is refused with the conflict banner; Keep My Changes writes mine", async () => {
        await fresh();
        const target = file("conflict.txt", "base\n");
        await openEditor(page, target);
        await caret(page, 1, 5);
        await page.keyboard.type(" mine");
        // Another writer changes the file; the save's base hash no longer matches.
        fs.writeFileSync(target, "theirs\n");
        await save(page);
        await page.waitForSelector(".ed-banner");
        expect(bytesOf(target).toString("utf8")).toBe("theirs\n");
        if (shots && name === "chromium") await page.screenshot({ path: path.join(shots, "editor-conflict.png") });
        await page.click(".ed-banner .ed-button-primary");
        await page.waitForFunction(() => !document.querySelector(".ed-banner"));
        await page.waitForFunction(() => document.documentElement.dataset.cmuxEditorStatus === "saved");
        expect(bytesOf(target).toString("utf8")).toBe("base mine\n");
      });

      test("a clean file follows a change on disk", async () => {
        await fresh();
        const target = file("follow.txt", "one\n");
        await openEditor(page, target);
        // The dev server's file watcher starts on open; a write it misses while starting is retried.
        let followed = false;
        for (let tries = 0; tries < 5 && !followed; tries += 1) {
          fs.writeFileSync(target, `two ${tries}\n`);
          followed = await page
            .waitForFunction(
              (text) => window.__cmuxEditor!.view()!.monacoEditor.getModel()!.getValue() === text,
              `two ${tries}\n`,
              { timeout: 3_000 },
            )
            .then(
              () => true,
              () => false,
            );
        }
        expect(followed).toBe(true);
        expect(await page.evaluate(() => document.documentElement.dataset.cmuxEditorStatus)).toBe("saved");
      });

      test("files outside the workspace and non-UTF-8 files open read only and never save", async () => {
        await fresh();
        const outside = file("outside.txt", "read me\n", readOnlyRoot);
        await openEditor(page, outside);
        expect(await page.textContent(".ed-note")).toContain("outside the workspace");
        await caret(page, 1, 1);
        await page.keyboard.type("x");
        await save(page);
        expect(await editorText(page)).toBe("read me\n");
        expect(bytesOf(outside).toString("utf8")).toBe("read me\n");
        if (shots && name === "chromium") await page.screenshot({ path: path.join(shots, "editor-readonly.png") });
        const latin1 = file("latin1.txt", Uint8Array.from([0x63, 0x61, 0x66, 0xe9, 0x0a]));
        await openEditor(page, latin1);
        expect(await page.textContent(".ed-note")).toContain("not UTF-8");
        await caret(page, 1, 1);
        await page.keyboard.type("x");
        await save(page);
        expect(bytesOf(latin1).equals(Buffer.from([0x63, 0x61, 0x66, 0xe9, 0x0a]))).toBe(true);
      });

      test("the empty state lists recent files and opens one", async () => {
        await fresh("dark");
        const recent = file("recent.md", "# recent\n");
        await openEditor(page, recent);
        await page.goto(`${base}/editor`);
        await page.waitForSelector('[data-viewer-empty="editor"]');
        expect(await page.textContent(".ve-title")).toBe("Open a file");
        const row = page.locator(".ve-recent", { hasText: path.basename(recent) }).first();
        await row.waitFor();
        if (shots && name === "chromium") await page.screenshot({ path: path.join(shots, "editor-empty.png") });
        await row.click();
        await page.waitForFunction(() => document.documentElement.dataset.cmuxEditorPhase === "ready");
        await page.waitForFunction(() => !!window.__cmuxEditor?.view()?.monacoEditor.getModel());
        expect(await editorText(page)).toBe("# recent\n");
      });

      test("the Word Wrap toggle writes the editor.wordWrap preference and applies it", async () => {
        await fresh("dark");
        const target = file("wrap.py", `${"x = 1  # long line ".repeat(20)}\n`);
        await openEditor(page, target, { highlighted: true });
        await page.click(".ed-toggle >> nth=0");
        await page.waitForFunction(() => window.__cmuxEditor!.view()!.monacoEditor.getRawOptions().wordWrap === "on");
        const preferences = await preferencesWhen((value) => value["editor.wordWrap"] === "on");
        expect(preferences["editor.wordWrap"]).toBe("on");
        if (shots && name === "chromium") await page.screenshot({ path: path.join(shots, "editor-dark.png") });
        await page.click(".ed-toggle >> nth=0");
        await preferencesWhen((value) => value["editor.wordWrap"] === "off");
        fs.rmSync(path.join(stateDir, "editor-preferences.json"), { force: true });
      });

      test("settings and theme.css from the look stream restyle the editor in place", async () => {
        await fresh();
        const target = file("look.ts", "const a = 1;\n");
        await openEditor(page, target, { highlighted: true });
        // The host's look event (the dev bridge plays the host's settings watcher).
        await page.evaluate(() =>
          (
            window as unknown as { __cmuxEditorDev: { emit(stream: string, data: unknown): void } }
          ).__cmuxEditorDev.emit("cmux.editor.look", {
            settings: { autoSave: "off", fontSize: 17, lineNumbers: "off", cursorStyle: "block" },
            themeCSS: ":root { --cmux-editor-line-highlight: #ff000040; }",
          }),
        );
        await page.waitForFunction(() => {
          const editor = window.__cmuxEditor!.view()!.monacoEditor;
          const style = getComputedStyle(document.querySelector(".monaco-editor")!);
          return (
            editor.getRawOptions().fontSize === 17 &&
            editor.getRawOptions().lineNumbers === "off" &&
            editor.getRawOptions().cursorStyle === "block" &&
            /^(#ff000040|rgba\(255, 0, 0, 0\.25\))$/.test(
              style.getPropertyValue("--vscode-editor-lineHighlightBackground").trim(),
            )
          );
        });
      });

      test("a large file opens with highlighting and the minimap off, and takes typing", async () => {
        await fresh();
        const line = "const value = compute(alpha, beta, gamma); // a line of a large file\n";
        const target = file("large.ts", line.repeat(Math.ceil((9 * 1024 * 1024) / line.length)));
        await openEditor(page, target);
        expect(await page.textContent(".ed-note")).toContain("Large file");
        const state = await page.evaluate(() => {
          const editor = window.__cmuxEditor!.view()!.monacoEditor;
          return {
            language: editor.getModel()!.getLanguageId(),
            minimap: editor.getRawOptions().minimap?.enabled,
          };
        });
        expect(state).toEqual({ language: "plaintext", minimap: false });
        await caret(page, 1, 1);
        await page.keyboard.type("// ");
        expect(await page.evaluate(() => window.__cmuxEditor!.view()!.monacoEditor.getModel()!.getLineContent(1))).toBe(
          `// ${line.trimEnd()}`,
        );
        if (shots && name === "chromium") await page.screenshot({ path: path.join(shots, "editor-large.png") });
      });

      test("screen reader mode works from the keyboard alone", async () => {
        await fresh();
        fs.writeFileSync(
          path.join(stateDir, "editor-preferences.json"),
          JSON.stringify({ "editor.accessibilitySupport": "on" }),
        );
        const target = file("a11y.ts", "first line\nsecond line\nthird line second\n");
        await openEditor(page, target);
        // Tab from the page start: the toolbar toggles, then the editor's input (a text area in
        // WebKit, an EditContext element in Chromium).
        let focused = false;
        for (let tries = 0; tries < 6 && !focused; tries += 1) {
          await page.keyboard.press("Tab");
          focused = await page.evaluate(
            () =>
              document.activeElement?.closest(".monaco-editor") != null &&
              document.activeElement?.getAttribute("role") === "textbox",
          );
        }
        expect(focused).toBe(true);
        const field = await page.evaluate(() => {
          const input = document.activeElement as HTMLElement;
          return {
            label: input.getAttribute("aria-label"),
            multiline: input.getAttribute("aria-multiline"),
            text: input instanceof HTMLTextAreaElement ? input.value : (input.textContent ?? ""),
          };
        });
        expect(field.label).toContain("a11y.ts");
        expect(field.multiline).toBe("true");
        // Screen reader mode puts the text around the caret into the input the screen reader reads.
        expect(field.text).toContain("first line");
        await page.keyboard.press("ArrowDown");
        // The line the caret is on, as the screen reader reads it from the input (updated on the next
        // frame in Chromium's EditContext).
        await page.waitForFunction(
          () => {
            const input = document.activeElement as HTMLElement;
            let text: string;
            let offset: number;
            if (input instanceof HTMLTextAreaElement) {
              text = input.value;
              offset = input.selectionStart;
            } else {
              const selection = getSelection()!;
              text = selection.focusNode?.textContent ?? "";
              offset = selection.focusOffset;
            }
            return text.split("\n")[text.slice(0, offset).split("\n").length - 1].trim() === "second line";
          },
          null,
          { timeout: 5_000 },
        );
        // Find (the dispatcher's `find` page command) announces its result in a live region.
        await page.keyboard.press("Meta+f");
        await page.waitForFunction(() => document.activeElement?.closest(".find-widget") != null);
        await page.keyboard.type("second");
        await page.waitForFunction(
          () => /2/.test(document.querySelector(".find-widget .matchesCount")?.textContent ?? ""),
          null,
          { timeout: 10_000 },
        );
        const announced = await page.evaluate(() =>
          [...document.querySelectorAll(".monaco-aria-container [role], .monaco-alert, .monaco-status")]
            .map((node) => node.textContent ?? "")
            .join(" | "),
        );
        expect(announced).toMatch(/second|2/);
        await page.keyboard.press("Escape");
        expect(
          await page.evaluate(
            () =>
              document.activeElement?.closest(".monaco-editor") != null &&
              document.activeElement?.getAttribute("role") === "textbox",
          ),
        ).toBe(true);
        fs.rmSync(path.join(stateDir, "editor-preferences.json"), { force: true });
      });
    });
  }
});
