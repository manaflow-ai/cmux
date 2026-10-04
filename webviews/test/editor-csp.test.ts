// The code editor page from the committed webviews-app bundle (Resources/markdown-viewer/webviews-app,
// as cmux-page://cmux.editor/ serves it) under the CSP the app sends (PageCSP.swift, the strict
// policy plus 'wasm-unsafe-eval', as the diff page has), in headless Chromium and WebKit: Monaco, its
// module worker, Shiki with the Oniguruma WebAssembly engine and the codicon font run with no
// 'unsafe-eval' and no policy violation. Without 'wasm-unsafe-eval' (the bare strict PageCSP) the page
// still works on Shiki's JavaScript engine, only slower. script-src 'self' plus 'wasm-unsafe-eval' is
// the least it needs; style-src needs 'unsafe-inline' (Monaco injects <style> rules).
// The host bridge is a stand-in installed before the page's scripts (Playwright init script, which
// a CSP does not govern). The Monaco chunks stay out of the diff and markdown pages' first load.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";

setDefaultTimeout(120_000);
const bundle = resolve(import.meta.dir, "../../Resources/markdown-viewer/webviews-app");
/** PageCSP.strict.header, byte for byte. */
const PAGE_CSP =
  "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:";
/** The editor page's CSP: PageCSP(script: ["'wasm-unsafe-eval'"]).header. */
const EDITOR_CSP =
  "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:";
/** The least the editor needs: no inline script, no 'unsafe-eval'. */
const MINIMAL_CSP =
  "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'";
const NO_INLINE_STYLE_CSP =
  "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; font-src 'self'";

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".css": "text/css",
  ".ttf": "font/ttf",
  ".wasm": "application/wasm",
};

let server: ReturnType<typeof Bun.serve> | null = null;
const policy = { value: EDITOR_CSP };

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
  } catch {}
}
const hasBundle = existsSync(join(bundle, "editor-page.html"));

beforeAll(() => {
  if (!hasBundle || installed.length === 0) return;
  server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request) {
      const pathname = new URL(request.url).pathname;
      const relative = normalize(pathname === "/" ? "/editor-page.html" : decodeURIComponent(pathname)).replace(
        /^\/+/,
        "",
      );
      const file = join(bundle, relative);
      if (!file.startsWith(`${bundle}/`) || !existsSync(file) || !statSync(file).isFile())
        return new Response("not found", { status: 404 });
      return new Response(readFileSync(file), {
        headers: {
          "Content-Type": TYPES[extname(file)] ?? "application/octet-stream",
          "Content-Security-Policy": policy.value,
        },
      });
    },
  });
});

afterAll(() => {
  void server?.stop(true);
});

/** The host bridge: one TypeScript file; every other op answers ok. */
const bridge = `
  window.__violations = [];
  document.addEventListener("securitypolicyviolation", (event) =>
    window.__violations.push(event.violatedDirective + " " + event.blockedURI));
  const subs = [];
  window.webkit = { messageHandlers: { cmuxPage: { postMessage: async (message) => {
    if (message.t === "sub") return { t: "ok", id: message.id, value: { sub: subs.push(message.stream) } };
    if (message.t !== "call") return null;
    if (message.op === "cmux.editor.config")
      return { t: "ok", id: message.id, value: {
        path: "/w/src/app.ts", hash: "h", size: 120, settings: { autoSave: "off" },
        text: "export function greet(name: string): string {\\n  return \`hello \${name}\`; // greet\\n}\\n" } };
    return { t: "ok", id: message.id, value: {} };
  } } } };
`;

const describeIf = hasBundle && installed.length > 0 ? describe : describe.skip;

for (const [name, engine] of installed) {
  describeIf(`editor page under the page CSP (${name})`, () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await engine.launch({ headless: true });
    });
    afterAll(async () => {
      await browser.close();
    });

    const run = async (csp: string) => {
      policy.value = csp;
      const page = await browser.newPage();
      const workers: string[] = [];
      page.on("worker", (worker) => workers.push(worker.url()));
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await page.addInitScript(bridge);
      await page.goto(`http://127.0.0.1:${server!.port}/editor-page.html`);
      const ready = await page
        .waitForFunction(() => document.documentElement.dataset.cmuxEditorHighlighted === "true", null, {
          timeout: 30_000,
        })
        .then(
          () => true,
          () => false,
        );
      // Typing goes through Monaco (and its worker sync) under the policy.
      if (ready) {
        await page.evaluate(() => window.__cmuxEditor!.view()!.monacoEditor.focus());
        await page.keyboard.type("x");
        await page.waitForTimeout(300);
      }
      const result = await page.evaluate(() => ({
        violations: (window as unknown as { __violations: string[] }).__violations,
        tokens: new Set(
          [...document.querySelectorAll(".view-line span span")].map((span) => getComputedStyle(span).color),
        ).size,
        codicon: [...document.fonts].some((font) => font.family.includes("codicon") && font.status === "loaded"),
        text: window.__cmuxEditor?.view()?.monacoEditor.getModel()?.getLineContent(1) ?? null,
        engine: document.documentElement.dataset.cmuxEditorEngine,
      }));
      await page.close();
      return { ready, workers, errors, ...result };
    };

    test("the editor CSP runs Monaco, its worker and Shiki's Oniguruma engine with no 'unsafe-eval'", async () => {
      const result = await run(EDITOR_CSP);
      expect(result.errors).toEqual([]);
      expect(result.violations).toEqual([]);
      expect(result.ready).toBe(true);
      expect(result.engine).toBe("oniguruma");
      expect(result.tokens).toBeGreaterThan(2);
      expect(result.workers.some((url) => url.endsWith("/chunks/editor-worker.mjs"))).toBe(true);
      expect(result.text).toBe("xexport function greet(name: string): string {");
    });

    test("the strict PageCSP (no 'wasm-unsafe-eval') falls back to the JavaScript engine", async () => {
      const result = await run(PAGE_CSP);
      expect(result.ready).toBe(true);
      expect(result.engine).toBe("javascript");
      expect(result.tokens).toBeGreaterThan(2);
      // The only refusal is the WebAssembly compile.
      expect(result.violations.every((violation) => violation.startsWith("script-src"))).toBe(true);
      expect(result.text).toBe("xexport function greet(name: string): string {");
    });

    test("script-src 'self' 'wasm-unsafe-eval' is enough; style-src needs 'unsafe-inline'", async () => {
      const minimal = await run(MINIMAL_CSP);
      expect(minimal.violations).toEqual([]);
      expect(minimal.ready).toBe(true);
      expect(minimal.engine).toBe("oniguruma");
      const noInlineStyle = await run(NO_INLINE_STYLE_CSP);
      expect(noInlineStyle.violations.some((violation) => violation.startsWith("style-src"))).toBe(true);
    });
  });
}

describe("bundle", () => {
  const pattern = /(?:^|[;}\s])(?:import|export)\s*(?:[^;'"()]*?from\s*)?["']([^"']+)["']/g;
  /** The files a page loads before any dynamic import: its HTML's scripts and styles, and their static imports. */
  const firstLoad = (entries: string[]) => {
    const seen = new Set<string>();
    const queue = entries.map((entry) => resolve(bundle, entry));
    while (queue.length > 0) {
      const file = queue.pop()!;
      if (seen.has(file)) continue;
      seen.add(file);
      if (file.endsWith(".html")) {
        for (const match of readFileSync(file, "utf8").matchAll(/(?:src|href)="\.\/([^"]+)"/g))
          queue.push(resolve(bundle, match[1]));
      } else if (file.endsWith(".mjs")) {
        for (const match of readFileSync(file, "utf8").matchAll(pattern))
          if (match[1].startsWith(".")) queue.push(resolve(dirname(file), match[1]));
      }
    }
    return [...seen].map((file) => file.slice(bundle.length + 1));
  };
  const monaco = (files: string[]) =>
    files.filter((file) => /^(chunks\/(view|editor|monaco-)|assets\/view\.css)/.test(file));

  test.if(hasBundle)("Monaco is lazy: no first load of the diff, markdown or editor page contains it", () => {
    expect(monaco(firstLoad(["diff-page.html", "chunks/diffSurface.mjs"]))).toEqual([]);
    expect(monaco(firstLoad(["markdown-page.html"]))).toEqual([]);
    expect(monaco(firstLoad(["main.mjs", "chunks/agentSessionSurface.mjs"]))).toEqual([]);
    // The editor page's own entry is small; Monaco comes with the first file.
    const editor = firstLoad(["editor-page.html"]);
    expect(editor).toContain("chunks/editor-page.mjs");
    expect(monaco(editor)).toEqual(["chunks/editor-page.mjs"]);
  });
});
