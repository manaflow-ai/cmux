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
//
// 28 browser tests in two engines take about 130 s on the CI runner (run-webviews-tests.sh):
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { stopDevServer } from "./support/devServer";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

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
    await warmDevServer(base, "/editor");
  }, 240_000);

  afterAll(() => {
    stopDevServer(server);
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
    await editorReady(page, options);
  }

  /** Waits until the page now loaded shows its file in Monaco. */
  async function editorReady(page: Page, options: { highlighted?: boolean } = {}) {
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

  /** Cmd-S, once the save it starts has ended: written, refused, or nothing to write. */
  async function save(page: Page) {
    // Each save the store ends is counted, after it set the status the host's answer gave.
    const before = await page.evaluate(() => {
      const store = window.__cmuxEditor!.store as NonNullable<Window["__cmuxEditor"]>["store"] & { saves?: number };
      if (store.saves === undefined) {
        store.saves = 0;
        const save = store.save.bind(store);
        store.save = async (...args) => {
          try {
            return await save(...args);
          } finally {
            store.saves! += 1;
          }
        };
      }
      return store.saves;
    });
    await page.keyboard.press("Meta+s");
    await page.waitForFunction(
      (before) => ((window.__cmuxEditor!.store as { saves?: number }).saves ?? 0) > before,
      before,
    );
  }

  /** The dev host's preferences file once `check` holds for it (the write is asynchronous). */
  async function preferencesWhen(check: (preferences: Record<string, unknown>) => boolean) {
    const target = path.join(stateDir, "editor-preferences.json");
    const read = () => {
      try {
        const preferences = JSON.parse(fs.readFileSync(target, "utf8"));
        return check(preferences) ? (preferences as Record<string, unknown>) : undefined;
      } catch {
        return undefined;
      }
    };
    // Read again each time the state folder changes.
    return new Promise<Record<string, unknown>>((resolve, reject) => {
      const watcher = fs.watch(stateDir, () => attempt());
      const timer = setTimeout(() => {
        watcher.close();
        reject(new Error("preferences never matched within 5 s"));
      }, 5_000);
      const attempt = () => {
        const preferences = read();
        if (!preferences) return;
        watcher.close();
        clearTimeout(timer);
        resolve(preferences);
      };
      attempt();
    });
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
        await installPaintedFrames(page);
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
        // Monaco's undo is CtrlCmd: Cmd on a Mac, Ctrl on the Linux CI runner.
        await page.keyboard.press("ControlOrMeta+z");
        expect(await editorText(page)).toBe("keep\r\nme\r\n");
        await save(page);
        expect(fs.statSync(target).mtimeMs).toBe(before);
        expect(bytesOf(target).equals(utf8("﻿keep\r\nme\r"))).toBe(true);
      });

      // Lawrence 2026-10-19: "All the web views should not have a built-in Cmd-P or Cmd-Shift-P.
      // They should all use the Swift version". Monaco's own command palette (F1, the context menu's
      // Command Palette) asks the host for the app's native palette and never shows its widget.
      test("Monaco's command palette opens the app's native palette, never its own", async () => {
        await fresh();
        const target = file("palette.ts", "const a = 1;\n");
        await openEditor(page, target);
        await caret(page, 1, 1);
        const asked = () =>
          page.evaluate(
            () => (window as unknown as { __cmuxEditorDev: { appActions: unknown[] } }).__cmuxEditorDev.appActions,
          );
        const monacoPalette = () =>
          page.evaluate(() => {
            const widget = document.querySelector<HTMLElement>(".quick-input-widget");
            return !!widget && widget.style.display !== "none" && widget.offsetHeight > 0;
          });
        await page.keyboard.press("F1");
        await page.waitForFunction(
          () =>
            (window as unknown as { __cmuxEditorDev: { appActions: unknown[] } }).__cmuxEditorDev.appActions.length > 0,
          null,
          { timeout: 10_000 },
        );
        expect(await asked()).toEqual(["commandPalette"]);
        expect(await monacoPalette()).toBe(false);
        expect(await editorText(page)).toBe("const a = 1;\n");
        // The context menu's Command Palette row runs the same command. The right-click menu is the
        // app's native menu (nativeEditorMenu.ts): the dev host notes its rows and picks the row
        // the test names, as the person would in the app's NSMenu.
        await page.evaluate(
          (id) =>
            ((window as unknown as { __cmuxEditorDev: { menuPick: string | null } }).__cmuxEditorDev.menuPick = id),
          "editor.action.quickCommand",
        );
        await page.click(".monaco-editor .view-lines", { button: "right" });
        await page.waitForFunction(
          () =>
            (window as unknown as { __cmuxEditorDev: { appActions: unknown[] } }).__cmuxEditorDev.appActions.length > 1,
          null,
          { timeout: 10_000 },
        );
        const rows = await page.evaluate(() =>
          (
            window as unknown as { __cmuxEditorDev: { menus: { items: { id: string; label: string }[] }[] } }
          ).__cmuxEditorDev.menus
            .at(-1)!
            .items.map((row) => row.label),
        );
        expect(rows).toContain("Command Palette");
        expect(await page.locator(".monaco-menu").count()).toBe(0);
        expect(await asked()).toEqual(["commandPalette", "commandPalette"]);
        expect(await monacoPalette()).toBe(false);
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

      // THEME-FLASH (user 2026-10-20, "for monaco editors there is flash of wrong theme"): Monaco's
      // first painted frame already has the page's theme. The editor used to be created with a theme
      // name defined only once Shiki loaded, so Monaco fell back to its light `vs` theme (white
      // #fffffe background) for the first frames, then switched.
      for (const scheme of ["dark", "light"] as const) {
        for (const fileName of ["flash.ts", "flash.txt"]) {
          test(`the first Monaco frame has the ${scheme} theme (${fileName})`, async () => {
            await fresh(scheme);
            // Every theme Monaco shows, from the moment its node exists (a mutation callback runs
            // before the frame paints): the base class and the editor background it resolved.
            await page.addInitScript(() => {
              const seen: { classes: string; background: string }[] = [];
              (window as unknown as { __themeFrames: typeof seen }).__themeFrames = seen;
              const record = () => {
                const node = document.querySelector<HTMLElement>(".monaco-editor");
                if (!node) return;
                const entry = {
                  classes: [...node.classList]
                    .filter((name) => /^(vs|vs-dark|hc-black|hc-light)$/.test(name))
                    .join(" "),
                  background: getComputedStyle(node).getPropertyValue("--vscode-editor-background").trim(),
                };
                const last = seen[seen.length - 1];
                if (!last || last.classes !== entry.classes || last.background !== entry.background) seen.push(entry);
              };
              new MutationObserver(record).observe(document, {
                subtree: true,
                childList: true,
                attributes: true,
                attributeFilter: ["class"],
              });
            });
            const target = file(fileName, "const a = 1;\n");
            await openEditor(page, target, { highlighted: fileName.endsWith(".ts") });
            // Shiki's themes are defined and set once its highlighter loads, plain text too; the
            // observer has seen that switch once a frame after it has painted.
            await page.evaluate(async () => {
              const view = window.__cmuxEditor!.view() as unknown as { syntax: { getHighlighter(): Promise<unknown> } };
              await view.syntax.getHighlighter();
              await window.cmuxPaintFrame();
            });
            const frames = await page.evaluate(
              () => (window as unknown as { __themeFrames: { classes: string; background: string }[] }).__themeFrames,
            );
            expect(frames.length).toBeGreaterThan(0);
            for (const frame of frames) {
              expect(frame.classes).toBe(scheme === "dark" ? "vs-dark" : "vs");
              // Monaco's own light background never shows: the page's `--cmux-editor-background`
              // (transparent by default) is the editor's from the first frame.
              expect(frame.background.toLowerCase()).not.toBe("#fffffe");
            }
          });
        }
      }

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

      test("resizing the editor does not show the scroller; scrolling it does", async () => {
        await fresh();
        // Counts every time an editor is marked scrolling (the mark clears 800 ms later, so a check
        // of the attribute alone could miss it).
        await page.addInitScript(() => {
          const scope = window as unknown as { scrollMarks: number };
          scope.scrollMarks = 0;
          new MutationObserver((records) => {
            for (const record of records)
              if ((record.target as Element).hasAttribute("data-cmux-scrolling")) scope.scrollMarks++;
          }).observe(document, { subtree: true, attributes: true, attributeFilter: ["data-cmux-scrolling"] });
        });
        const lines = Array.from({ length: 200 }, (_, index) => `const line${index} = ${index};`).join("\n");
        await openEditor(page, file("long.ts", `${lines}\n`), { highlighted: true });
        const marks = () => page.evaluate(() => (window as unknown as { scrollMarks: number }).scrollMarks);
        const before = await marks();
        // A pane or window resize changes the scroll size, not the scroll position.
        await page.setViewportSize({ width: 700, height: 420 });
        await page.waitForFunction(() => window.__cmuxEditor!.view()!.monacoEditor.getLayoutInfo().width < 720);
        await page.evaluate(
          () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        );
        expect(await marks()).toBe(before);
        await page.evaluate(() => window.__cmuxEditor!.view()!.monacoEditor.setScrollTop(400));
        await page.waitForFunction(
          (count) => (window as unknown as { scrollMarks: number }).scrollMarks > count,
          before,
        );
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

      // PANE-FOCUS (user 2026-10-20, "monaco editor on focus does not get focus"): the app gives
      // the page's web view the keyboard (pane click, Cmd-Opt-Arrow, tab switch, new tab) and sends
      // `focusContent`; with nothing focused in the page, typing must land in Monaco, not the body.
      const focusContent = (page: Page) =>
        page.evaluate(() =>
          (
            window as unknown as { __cmuxEditorDev: { emit: (stream: string, data: unknown) => boolean } }
          ).__cmuxEditorDev.emit("cmux.page.command", { command: "focusContent" }),
        );
      const editorHasFocus = (page: Page) =>
        page.evaluate(() => window.__cmuxEditor!.view()!.monacoEditor.hasTextFocus());

      test("the host's focusContent puts the keyboard in Monaco without a click", async () => {
        await fresh();
        const target = file("focus.ts", "const a = 1;\n");
        await openEditor(page, target);
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        expect(await editorHasFocus(page)).toBe(false);
        expect(await focusContent(page)).toBe(true);
        await page.waitForFunction(() => window.__cmuxEditor!.view()!.monacoEditor.hasTextFocus(), null, {
          timeout: 5_000,
        });
        await page.keyboard.type("x");
        expect(await editorText(page)).toBe("xconst a = 1;\n");
      });

      test("focusContent that arrives before Monaco mounts focuses the editor once it mounts", async () => {
        await fresh();
        const target = file("early.ts", "let b = 2;\n");
        await page.goto(`${base}/editor?file=${encodeURIComponent(target)}`);
        // As soon as the page subscribes to its commands (before the Monaco chunk loads).
        await page.waitForFunction(
          () =>
            (
              window as unknown as { __cmuxEditorDev?: { emit: (stream: string, data: unknown) => boolean } }
            ).__cmuxEditorDev?.emit("cmux.page.command", { command: "focusContent" }) === true,
          null,
          { timeout: 60_000, polling: 10 },
        );
        // The same document: a second goto would load a new one and drop the request.
        await editorReady(page);
        await page.waitForFunction(() => window.__cmuxEditor!.view()!.monacoEditor.hasTextFocus(), null, {
          timeout: 5_000,
        });
        await page.keyboard.type("y");
        expect(await editorText(page)).toBe("ylet b = 2;\n");
      });

      test("the page getting the keyboard back focuses Monaco only when nothing in it has focus", async () => {
        await fresh();
        const target = file("keep.ts", "find me\nfind me\n");
        await openEditor(page, target);
        // The find field has focus: getting the keyboard back keeps it there.
        await page.keyboard.press("Meta+f");
        await page.waitForFunction(() => document.activeElement?.closest(".find-pill") != null);
        await page.evaluate(() => window.dispatchEvent(new FocusEvent("focus")));
        expect(await focusContent(page)).toBe(true);
        // A request kept for later tries again on the next frame.
        await page.evaluate(() => window.cmuxPaintFrame());
        expect(await page.evaluate(() => document.activeElement?.closest(".find-pill") != null)).toBe(true);
        // Nothing has focus: the window's focus (WebKit's first responder) lands in Monaco.
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await page.evaluate(() => window.dispatchEvent(new FocusEvent("focus")));
        await page.waitForFunction(() => window.__cmuxEditor!.view()!.monacoEditor.hasTextFocus(), null, {
          timeout: 5_000,
        });
      });

      test("Cmd-F shows the shared find pill, never Monaco's find widget", async () => {
        await fresh();
        const target = file("pill.ts", "alpha beta\nalpha gamma\nAlpha delta\n");
        await openEditor(page, target);
        await page.keyboard.press("Meta+f");
        await page.waitForFunction(() => document.activeElement?.closest(".find-pill") != null);
        await page.keyboard.type("alpha");
        await page.waitForFunction(() => document.querySelector(".find-pill__count")?.textContent === "1 of 3");
        // Monaco's own widget never shows.
        expect(
          await page.evaluate(() => {
            const widget = document.querySelector<HTMLElement>(".find-widget");
            return widget != null && widget.classList.contains("visible") && widget.offsetParent != null;
          }),
        ).toBe(false);
        // Return steps and selects the next match in the editor.
        await page.keyboard.press("Enter");
        await page.waitForFunction(() => document.querySelector(".find-pill__count")?.textContent === "2 of 3");
        expect(
          await page.evaluate(() => window.__cmuxEditor!.view()!.monacoEditor.getSelection()?.startLineNumber),
        ).toBe(2);
        // Match Case drops "Alpha".
        await page.click(".find-pill__button[aria-pressed]");
        await page.waitForFunction(() =>
          (document.querySelector(".find-pill__count")?.textContent ?? "").endsWith("of 2"),
        );
        // Escape hides the pill and gives Monaco the keyboard back.
        await page.focus(".find-pill__field");
        await page.keyboard.press("Escape");
        await page.waitForFunction(() => document.querySelector(".find-pill") == null);
        await page.waitForFunction(() => window.__cmuxEditor!.view()!.monacoEditor.hasTextFocus(), null, {
          timeout: 5_000,
        });
      });

      test("Replace (the replace page command) opens the find pill's replace row, never Monaco's widget", async () => {
        await fresh();
        const target = file("replace.ts", "old one\nold two\n");
        await openEditor(page, target);
        await page.evaluate(() =>
          (
            window as unknown as { __cmuxEditorDev: { emit: (stream: string, data: unknown) => boolean } }
          ).__cmuxEditorDev.emit("cmux.page.command", { command: "replace" }),
        );
        await page.waitForSelector(".find-pill__replace");
        expect(await page.evaluate(() => document.querySelector(".find-widget.visible.replaceToggled") != null)).toBe(
          false,
        );
        await page.fill(".find-pill__field", "old");
        await page.fill(".find-pill__replace .find-pill__field", "new");
        await page.click(".find-pill__replace-all");
        await page.waitForFunction(
          () => window.__cmuxEditor!.view()!.monacoEditor.getModel()!.getValue() === "new one\nnew two\n",
        );
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
        await page.waitForFunction(() => document.activeElement?.closest(".find-pill") != null);
        await page.keyboard.type("second");
        await page.waitForFunction(
          () => /2/.test(document.querySelector(".find-pill__count")?.textContent ?? ""),
          null,
          { timeout: 10_000 },
        );
        const announced = await page.evaluate(() =>
          [
            ...document.querySelectorAll(
              ".find-pill__count[aria-live], .monaco-aria-container [role], .monaco-alert, .monaco-status",
            ),
          ]
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
