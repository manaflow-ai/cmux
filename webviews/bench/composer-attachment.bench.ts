// Drop-to-chip, Send-enabled and immediate Send dispatch, in ms. Linux, Bun and system Chrome.
//   cmux-ci test --setup webviews -- bash scripts/measure/composer-attachment.sh
// Drop disk-backed 64 KiB and 100 MiB files into the production pane with the mock daemon. A
// loopback JSON host supplies native paths or actually decodes and stages the upload chunks.
// Measure dispatch on separate drops: clicking as soon as Send enables can remove the chip.
import { closeSync, mkdtempSync, openSync, rmSync, truncateSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { build } from "vite";
import { attachmentWithoutCwd } from "../test/support/attachmentWithoutCwd";
import { chromium } from "./browsers";
import type { Page } from "playwright";
import type {} from "../src/agent-session/acpmux/pane/bridgeGlobals";

const root = process.argv[2] ?? path.resolve(import.meta.dir, "..");
const dir = mkdtempSync(path.join(tmpdir(), "cmux-composer-attachment-"));
const out = path.join(dir, "pane");
const rounds = 5;
type Sample = {
  chipMs?: number;
  chipWidth?: number;
  chipHeight?: number;
  sendEnabledMs?: number;
  dispatchMs?: number;
};

// The same 640×480 image at either size. Its optional text chunk changes file I/O without
// changing pixel work. PNG chunks measure the payload length and CRC the type plus payload.
async function diskFixture(page: Page, bytes: number, ext: string): Promise<string> {
  const file = path.join(dir, bytes + "." + ext);
  if (ext === "png") {
    const png = Buffer.from(
      await page.evaluate(() => {
        const canvas = Object.assign(document.createElement("canvas"), { width: 640, height: 480 });
        return canvas.toDataURL("image/png").split(",")[1]!;
      }),
      "base64",
    );
    const padded = Buffer.alloc(bytes, 32);
    const start = png.length - 12; // IEND
    const end = bytes - 12;
    png.copy(padded, 0, 0, start);
    padded.writeUInt32BE(end - start - 12, start);
    padded.write("tEXtFixture\0", start + 4);
    padded.writeUInt32BE(Bun.hash.crc32(padded.subarray(start + 4, end - 4)), end - 4);
    png.copy(padded, end, start);
    writeFileSync(file, padded);
  } else {
    writeFileSync(file, "");
    truncateSync(file, bytes);
  }
  return file;
}

declare global {
  interface Window {
    attachmentSample: Sample;
    attachmentStart: number;
  }
}

async function trial(page: Page, url: string, file: string, click: boolean) {
  await page.goto(url);
  await page.waitForFunction(() => typeof window.cmuxAcpmuxActions?.["chat.send"] === "function");
  await page.locator(".acpmux-composer-prompt").waitFor();
  await page.evaluate(() => {
    if (window.cmuxAcpmuxBridge?.composerState?.()?.attachments.length)
      throw new Error("trial started with an attachment");
    const input = document.createElement("input");
    input.id = "bench-file";
    input.type = "file";
    input.hidden = true;
    document.body.append(input);
  });
  await page.locator("#bench-file").setInputFiles(file);
  await page.evaluate((click) => {
    const host = window;
    const actions = window.cmuxAcpmuxActions!;
    const send = actions["chat.send"]!;
    actions["chat.send"] = (params) => {
      if (!Array.isArray(params.attachments) || !params.attachments.length) throw new Error("sent without attachment");
      host.attachmentSample.dispatchMs = performance.now() - host.attachmentStart;
      return send(params);
    };
    const data = new DataTransfer();
    data.items.add((document.querySelector("#bench-file") as HTMLInputElement).files![0]!);
    const sample: Sample = (host.attachmentSample = {});
    const observer = new MutationObserver(() => {
      const ms = performance.now() - host.attachmentStart;
      if (sample.chipMs === undefined && window.cmuxAcpmuxBridge?.composerState?.()?.attachments.length) {
        // The editor's inline attachment atom may still be an empty slot. Only time the mounted
        // ready chip itself: a pending placeholder can occupy real space while the upload runs.
        const chip = document.querySelector<HTMLElement>(
          '.acpmux-composer .acpmux-attachment:not(.acpmux-attachment-pending):not(.acpmux-attachment-failed):not([aria-busy="true"]), .acpmux-composer .acpmux-md-inline-chip[data-state="ready"]',
        );
        const rect = chip?.getBoundingClientRect();
        if (rect && rect.width > 0 && rect.height > 0) {
          sample.chipMs = performance.now() - host.attachmentStart;
          sample.chipWidth = rect.width;
          sample.chipHeight = rect.height;
        }
      }
      const button = document.querySelector<HTMLButtonElement>("button.acpmux-send-ready:not(:disabled)");
      if (sample.sendEnabledMs === undefined && button) {
        sample.sendEnabledMs = ms;
        if (click) button.click();
      }
      if (sample.sendEnabledMs !== undefined && (click || sample.chipMs !== undefined)) observer.disconnect();
    });
    observer.observe(document.body, { subtree: true, attributes: true, childList: true });
    host.attachmentStart = performance.now();
    document.body.dispatchEvent(new DragEvent("drop", { dataTransfer: data, bubbles: true, cancelable: true }));
  }, click);
  await page.waitForFunction(
    (click) => {
      const sample = window.attachmentSample;
      return click
        ? sample.dispatchMs !== undefined
        : sample.chipMs !== undefined && sample.sendEnabledMs !== undefined;
    },
    click,
    { timeout: 30_000 },
  );
  return page.evaluate(() => window.attachmentSample);
}

let fixture = "";
let staged: number | undefined;
let size = 0;
let chunks = 0;
let base64Chars = 0;
const stagedPath = path.join(dir, "staged");
const releases: (() => unknown)[] = [];
let loading = false;
let simulation: Promise<void> | undefined;
let simulationFailure = "";

// Keep the long transcript active through all the samples, including a base revision that stages
// 100 MiB. Print the simulator's own exit status and verdict, including layout violations.
async function simulate() {
  while (loading) {
    const sim = Bun.spawn(["bun", "scripts/chat-sim.ts", "--long", "300"], {
      cwd: root,
      stdout: "pipe",
      stderr: "pipe",
    });
    const [output, errors, status] = await Promise.all([
      new Response(sim.stdout).text(),
      new Response(sim.stderr).text(),
      sim.exited,
    ]);
    console.error("chat-sim exit=" + status, output, errors);
    if (!/long-300: \d+ steps/.test(output + errors)) throw new Error("chat-sim did not run 300 turns");
  }
}

try {
  await build({
    configFile: path.join(root, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
    plugins: [attachmentWithoutCwd],
  });
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      if (
        pathname === "/attachment-host" &&
        request.method === "POST" &&
        request.headers.get("origin") === new URL(request.url).origin
      ) {
        const { method, params } = await request.json();
        switch (method) {
          case "chat.attach.dropped":
            return Response.json({ items: [{ path: fixture, folder: false }] });
          case "chat.upload.begin":
            staged = openSync(stagedPath, "w");
            return Response.json({ token: "attachment", size: params.size, chunkSize: 512 * 1024 });
          case "chat.upload.chunk": {
            if (staged === undefined || params.offset !== size) throw new Error("bad chunk offset");
            const data = Buffer.from(params.data, "base64");
            size += writeSync(staged, data);
            chunks++;
            base64Chars += params.data.length;
            return Response.json({ offset: size });
          }
          case "chat.upload.finish":
            if (staged === undefined) throw new Error("missing stage");
            closeSync(staged);
            staged = undefined;
            return Response.json({ path: stagedPath });
          default:
            throw new Error("unexpected host method " + method);
        }
      }
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response(null, { status: 404 });
    },
  });
  releases.push(() => server.stop(true));
  const browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  for (const duress of process.env.CMUX_ATTACHMENT_DURESS === "1" ? [false, true] : [false]) {
    if (duress) {
      loading = true;
      simulation = simulate().catch((error) => {
        simulationFailure = String(error);
      });
    }
    for (const ext of ["zip", "png"])
      for (const bytes of [64 * 1024, 100 * 1024 * 1024]) {
        const page = await browser.newPage();
        fixture = await diskFixture(page, bytes, ext);
        const rows: (Sample & {
          click: boolean;
          chunks: number;
          stagedBytes: number;
          base64Chars: number;
        })[] = [];
        await page.addInitScript(() => {
          localStorage.clear();
          sessionStorage.clear();
          async function postMessage({ method, params }: { method: string; params: unknown }) {
            if (!method.startsWith("chat.upload.") && method !== "chat.attach.dropped")
              return { ok: true, value: null };
            const response = await fetch("/attachment-host", {
              method: "POST",
              body: JSON.stringify({ method, params }),
            });
            if (!response.ok) throw new Error(method + " failed: " + response.status);
            return { ok: true, value: await response.json() };
          }
          Object.assign(window, {
            cmuxAcpmuxActions: {
              ready: async () => ({
                protocolVersion: 1,
                transport: "mock",
                sessionId: "mock-session",
              }),
            },
            webkit: { messageHandlers: { agentSession: { postMessage } } },
          });
        });
        for (let round = 0; round <= rounds; round++)
          for (const click of [false, true]) {
            size = chunks = base64Chars = 0;
            const url = server.url.href + (ext === "zip" ? "?mock&noCwd" : "?mock");
            const sample = await trial(page, url, fixture, click);
            if (simulationFailure) throw new Error(simulationFailure);
            if (round > 0) rows.push({ ...sample, click, chunks, base64Chars, stagedBytes: size });
          }
        await page.close();
        const median = (metric: keyof Sample, click: boolean) => {
          const values = rows
            .filter((row) => row.click === click)
            .map((row) => row[metric]!)
            .sort((a, b) => a - b);
          return Number(values[Math.floor(values.length / 2)]!.toFixed(1));
        };
        console.log(
          JSON.stringify({
            ext,
            bytes,
            rounds,
            duress,
            chipMs: median("chipMs", false),
            chipWidth: median("chipWidth", false),
            chipHeight: median("chipHeight", false),
            sendEnabledMs: median("sendEnabledMs", false),
            dispatchMs: median("dispatchMs", true),
            maxChunks: Math.max(...rows.map((row) => row.chunks)),
            maxStagedBytes: Math.max(...rows.map((row) => row.stagedBytes)),
            maxBase64Chars: Math.max(...rows.map((row) => row.base64Chars)),
          }),
        );
      }
  }
} finally {
  loading = false;
  await simulation;
  for (const release of releases.reverse()) await release();
  if (staged !== undefined) closeSync(staged);
  rmSync(dir, { recursive: true, force: true });
}
