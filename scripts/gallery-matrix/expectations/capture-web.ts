#!/usr/bin/env bun
// Captures every web surface in design/visual-expectations/web/ from a built static gallery
// (`bun run gallery:build`), light and dark, into the gate's layout:
// OUT/web/<surface>/<state>-<scheme>.png, a sidecar .json (keep boxes resolved from their selectors,
// in image pixels) and OUT/web/renderer.json.
//
//   CMUX_GALLERY_IN_VM=1 bun capture-web.ts --expectations design/visual-expectations --gallery-dir dist/gallery --out OUT [--surfaces ui.menu,ui.dialog]
//
// Deterministic by construction: device scale 1, UTC, en-US, Reduce Motion, CSS animations and the
// caret off, web fonts loaded, the gallery's own frozen clock (src/gallery/clock.ts). Each state is
// rendered twice; a state whose two renders differ is marked nondeterministic and never judged.
// Browsers run only on the fleet (`cmux-ci test`), like runner.ts.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, extname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { diff } from "./gate";
import { keepFor, loadSurfaces, shotPath, type CaptureSpec, type Scheme, type Surface } from "./expectations";

const CONTEXT = 24;
const DEFAULT_SIZE = { width: 760, height: 520 };

async function serve(root: string) {
  const types: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf" };
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const file = resolve(root, decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "") || "index.html");
      if (!file.startsWith(resolve(root))) return new Response("forbidden", { status: 403 });
      try {
        return new Response(await readFile(file), { headers: { "content-type": types[extname(file)] ?? "application/octet-stream" } });
      } catch {
        return new Response("not found", { status: 404 });
      }
    },
  });
  return { base: `http://127.0.0.1:${server.port}`, close: () => server.stop() };
}

/** The installed fonts, hashed: a font package update moves every glyph, so it is part of the renderer. */
function fontHash(): string {
  try {
    const list = execFileSync("fc-list", [":", "family", "style"], { encoding: "utf8" }).split("\n").sort().join("\n");
    return createHash("sha256").update(list).digest("hex").slice(0, 12);
  } catch {
    return "no-fc-list";
  }
}

type Shot = { png: Buffer; keep: { name: string; box: [number, number, number, number] }[]; error?: string };

async function render(browser: Browser, base: string, surface: Surface, capture: CaptureSpec, scheme: Scheme): Promise<Shot> {
  const width = capture.width ?? DEFAULT_SIZE.width;
  const height = capture.height ?? DEFAULT_SIZE.height;
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: 1,
    colorScheme: scheme,
    locale: "en-US",
    timezoneId: "UTC",
    reducedMotion: "reduce",
  });
  try {
    const page = await context.newPage();
    // Play steps act through trusted input (gallery/play.ts), as in runner.ts.
    await page.exposeFunction("cmuxGalleryInput", async (a: { kind: string; x?: number; y?: number; text?: string; width?: number }) => {
      const at = () => page.mouse.move(a.x ?? 0, a.y ?? 0);
      if (a.kind === "click") await page.mouse.click(a.x ?? 0, a.y ?? 0);
      else if (a.kind === "contextmenu") await page.mouse.click(a.x ?? 0, a.y ?? 0, { button: "right" });
      else if (a.kind === "hover" || a.kind === "move") await at();
      else if (a.kind === "down") (await at(), await page.mouse.down());
      else if (a.kind === "up") (await at(), await page.mouse.up());
      else if (a.kind === "type") await page.keyboard.type(a.text ?? "");
      else if (a.kind === "press") await page.keyboard.press(a.text ?? "");
      else if (a.kind === "resize") await page.setViewportSize({ width: Math.round(a.width ?? width), height });
    });
    await page.exposeFunction("cmuxGalleryStep", async () => undefined);
    const params = new URLSearchParams({
      entry: capture.entry!,
      variant: capture.variant!,
      colorScheme: scheme,
      locale: "en",
      width: String(width),
      height: String(height),
      reducedMotion: "1",
    });
    await page.goto(`${base}/frame.html?${params}`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, null, { timeout: 20_000 });
    const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
    if (ready !== "1") return { png: Buffer.alloc(0), keep: [], error: `stage reported ready=${ready}` };
    await page.evaluate(() => document.fonts.ready.then(() => undefined));
    const clip = await clipOf(page, capture.selector);
    const png = await page.screenshot({ animations: "disabled", caret: "hide", ...(clip ? { clip } : {}) });
    const regions = keepFor(surface, capture).filter((r) => r.selector);
    const keep: Shot["keep"] = [];
    for (const region of regions) {
      const boxes = await page.evaluate(
        (selector) => [...document.querySelectorAll(selector)].map((el) => el.getBoundingClientRect()).filter((r) => r.width && r.height).map((r) => [r.left, r.top, r.width, r.height]),
        region.selector!,
      );
      for (const [x, y, w, h] of boxes as [number, number, number, number][])
        keep.push({ name: region.name, box: [Math.round(x - (clip?.x ?? 0)), Math.round(y - (clip?.y ?? 0)), Math.round(w), Math.round(h)] });
    }
    return { png, keep };
  } catch (error) {
    return { png: Buffer.alloc(0), keep: [], error: String(error).slice(0, 300) };
  } finally {
    await context.close();
  }
}

/** The stage's surface (`selector`, else `[data-gallery-capture]`, else `#root`) plus a margin, inside the viewport. */
async function clipOf(page: Page, selector?: string) {
  const r = await page.evaluate((selector) => {
    const el = (selector && document.querySelector(selector)) || document.querySelector("[data-gallery-capture]") || document.querySelector("#root");
    if (!el) return null;
    const b = el.getBoundingClientRect();
    return { l: b.left, t: b.top, r: b.right, b: b.bottom, w: innerWidth, h: innerHeight };
  }, selector ?? null);
  if (!r) return undefined;
  const x = Math.max(0, Math.floor(r.l - CONTEXT));
  const y = Math.max(0, Math.floor(r.t - CONTEXT));
  const width = Math.min(r.w, Math.ceil(r.r + CONTEXT)) - x;
  const height = Math.min(r.h, Math.ceil(r.b + CONTEXT)) - y;
  return width > 0 && height > 0 ? { x, y, width, height } : undefined;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: { expectations: { type: "string" }, "gallery-dir": { type: "string" }, out: { type: "string" }, surfaces: { type: "string" } },
  });
  if (process.env.CMUX_GALLERY_IN_VM !== "1") throw new Error("browsers run on the fleet only: CMUX_GALLERY_IN_VM=1 under cmux-ci test");
  for (const name of ["expectations", "gallery-dir", "out"] as const) if (!values[name]) throw new Error(`--${name} is required`);
  const only = values.surfaces ? new Set(values.surfaces.split(",")) : undefined;
  const surfaces = loadSurfaces(values.expectations!, ["web"]).filter((s) => !only || only.has(s.id));
  const out = values.out!;
  const server = await serve(values["gallery-dir"]!);
  const shell = process.env.CMUX_CHROME_HEADLESS_SHELL;
  const browser = await chromium.launch({ headless: true, ...(shell ? { executablePath: shell } : { channel: "chrome" }) });
  mkdirSync(join(out, "web"), { recursive: true });
  writeFileSync(
    join(out, "web", "renderer.json"),
    `${JSON.stringify({ id: `chrome ${browser.version().split(".").slice(0, 2).join(".")}; ${process.platform}; fonts ${fontHash()}` }, null, 2)}\n`,
  );
  let failures = 0;
  try {
    for (const surface of surfaces)
      for (const capture of surface.captures)
        for (const scheme of surface.schemes) {
          const file = shotPath(out, surface, capture.state, scheme);
          mkdirSync(dirname(file), { recursive: true });
          const first = await render(browser, server.base, surface, capture, scheme);
          const sidecar: Record<string, unknown> = { scale: 1, keep: first.keep };
          if (first.error) {
            sidecar.error = first.error;
            failures++;
          } else {
            writeFileSync(file, first.png);
            const again = await render(browser, server.base, surface, capture, scheme);
            if (again.error || diff(PNG.sync.read(first.png), PNG.sync.read(again.png), 0).pixels) sidecar.nondeterministic = true;
          }
          writeFileSync(file.replace(/\.png$/, ".json"), `${JSON.stringify(sidecar, null, 2)}\n`);
          console.log(JSON.stringify({ surface: surface.id, state: capture.state, scheme, ...sidecar, keep: first.keep.length }));
        }
  } finally {
    await browser.close();
    server.close();
  }
  console.log(`captured ${surfaces.length} web surfaces; ${failures} states failed to render`);
}

