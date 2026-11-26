// Production page + real acpmux Unix socket, driven by the ignored Rust fixture test. The
// harness substitutes for the native URL scheme, page bridge and Cmd-F command dispatcher.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createConnection } from "node:net";
import path from "node:path";
import { createInterface } from "node:readline";
import { inflateRawSync } from "node:zlib";
import { launchBrowser } from "./agent-pane/mockLaunch.mjs";

const [pages, socketPath, key, newest] = process.argv.slice(2);
const newestText = `review turn ${newest}`;
const dayOne = "day one needle";
const names = new Map([
  ["cmux.terminal_history.page", "_acpmux/chat_transcript_page"],
  ["cmux.terminal_history.find", "_acpmux/chat_transcript_find"],
]);

// AcpmuxStatusClient.exchange sends initialize + request on a fresh socket for each call.
async function rpc(method, params) {
  const connection = createConnection(socketPath);
  connection.setTimeout(10_000, () => connection.destroy(new Error("Unix RPC timed out")));
  const lines = createInterface({ input: connection });
  try {
    const request = (id, method, params) => JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    connection.write(
      request(1, "initialize", {
        protocolVersion: 1,
        clientInfo: { name: "cmux-next-agent-pane", version: "1" },
      }) + request(2, method, { ...params, key, cwd: "/work/api" }),
    );
    for await (const line of lines) {
      assert.ok(Buffer.byteLength(line) <= 1024 * 1024, "native reply ceiling");
      const msg = JSON.parse(line);
      if (msg.error) throw new Error(JSON.stringify(msg.error));
      if (msg.id === 2) return msg.result;
    }
    throw new Error("Unix RPC closed before reply");
  } finally {
    lines.close();
    connection.destroy();
  }
}

const mime = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".woff2": "font/woff2",
};
const origin = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(request) {
    const resource = new URL(request.url).pathname;
    if (resource === "/favicon.ico") return new Response(null, { status: 204 });
    const file = path.resolve(pages, "." + resource);
    if (!file.startsWith(path.resolve(pages) + "/")) return new Response(null, { status: 404 });
    try {
      const bytes = await readFile(file).catch(async (error) => {
        if (error.code !== "ENOENT") throw error;
        return inflateRawSync(await readFile(file + ".deflate"));
      });
      return new Response(bytes, {
        headers: {
          "Content-Type": mime[path.extname(file)] ?? "application/octet-stream",
          "Content-Security-Policy":
            "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:",
        },
      });
    } catch {
      return new Response(null, { status: 404 });
    }
  },
});

const browser = await launchBrowser();
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const evidence = process.env.FAST_CHECKS_OUT;
  const errors = [];
  page.on("pageerror", (err) => {
    errors.push(err.message);
    console.error("page error:", err.message);
  });
  page.on("requestfailed", (request) =>
    console.error("page request failed:", request.url(), request.failure()?.errorText),
  );
  const entry = await readFile(path.join(pages, "terminal-history/index.html"), "utf8");
  assert.match(entry, /__shared\/page-terminal-history\.js/);
  await page.exposeFunction("fetchTerminalTranscript", (op, params) => rpc(names.get(op), params));
  await page.addInitScript(
    ({ newestText }) => {
      let commandSubscription;
      window.webkit = {
        messageHandlers: {
          cmuxPage: {
            async postMessage(msg) {
              if (msg.t === "sub" && msg.stream === "cmux.page.command") commandSubscription = msg.id;
              let value = msg.t === "sub" ? { sub: msg.id } : {};
              if (msg.t === "call" && msg.op.startsWith("cmux.terminal_history.")) {
                window.historyFirstRequest ??= performance.now();
                value = await window.fetchTerminalTranscript(msg.op, msg.params);
              }
              return { t: "ok", id: msg.id, value };
            },
          },
        },
      };
      document.addEventListener(
        "keydown",
        (event) => {
          if (event.metaKey && event.key === "f") {
            event.preventDefault();
            window.__cmuxPageReceive({
              t: "ev",
              sub: commandSubscription,
              seq: 1,
              data: { command: "find" },
            });
          }
        },
        true,
      );
      const rendered = new MutationObserver(() => {
        const row = Array.from(document.querySelectorAll("article p")).find((p) => p.textContent === newestText);
        if (!row) return;
        rendered.disconnect();
        const visibility = new IntersectionObserver(([entry]) => {
          if (!entry.isIntersecting) return;
          visibility.disconnect();
          requestAnimationFrame(() => {
            window.historyVisible = performance.now();
          });
        });
        visibility.observe(row);
      });
      rendered.observe(document, { subtree: true, childList: true, characterData: true });
    },
    { newestText },
  );
  await page.goto(new URL("terminal-history/index.html", origin.url).href, { waitUntil: "domcontentloaded" });
  await page
    .waitForFunction(() => Number.isFinite(window.historyVisible), undefined, { timeout: 5000 })
    .catch(async (error) => {
      const view = await page.evaluate(() => {
        const el = document.querySelector(".terminal-history-scroll");
        return {
          rows: document.querySelectorAll("article").length,
          scrollTop: el?.scrollTop,
          clientHeight: el?.clientHeight,
          scrollHeight: el?.scrollHeight,
          error: document.querySelector("[role=alert]")?.textContent,
        };
      });
      throw new Error(`Latest turn did not become visible: ${JSON.stringify(view)}`, { cause: error });
    });
  const metrics = await page.evaluate(() => ({
    navigation_to_visible_ms: window.historyVisible,
    first_request_to_visible_ms: window.historyVisible - window.historyFirstRequest,
  }));
  console.log("terminal_history_visible_600mib", JSON.stringify(metrics));
  if (evidence) await page.screenshot({ path: path.join(evidence, "terminal-history-latest.png") });

  await page.locator("article strong").filter({ hasText: "complete" }).first().waitFor({ state: "attached" });
  const tool = page.locator("article details").last();
  assert.equal(await tool.evaluate((el) => el.open), false);
  await tool.locator("summary").click();
  await tool
    .getByText(/fixture.log/)
    .first()
    .waitFor({ state: "visible" });
  await tool.locator("summary").click();

  // Follow the user's scroll path, asserting a real older page is inserted at each step.
  const scroll = await page.evaluate(
    async ({ dayOne }) => {
      const viewport = document.querySelector(".terminal-history-scroll");
      const first = () => viewport.querySelector("article p")?.textContent;
      const times = [];
      const ordinal = (text) => (text === dayOne ? 0 : Number(/^review turn (\d+)$/.exec(text)?.[1]));
      for (let n = ordinal(first()); n > 0; n = ordinal(first())) {
        const started = performance.now();
        const changed = new Promise((resolve, reject) => {
          const observer = new MutationObserver(() => {
            if (ordinal(first()) >= n || !Number.isFinite(ordinal(first()))) return;
            observer.disconnect();
            clearTimeout(deadline);
            // Let layout restore the existing row before the next scroll gesture.
            requestAnimationFrame(() => requestAnimationFrame(resolve));
          });
          const deadline = setTimeout(() => {
            observer.disconnect();
            reject(new Error(`scroll stalled at turn ${n}, scrollTop=${viewport.scrollTop}`));
          }, 10_000);
          observer.observe(viewport, { subtree: true, childList: true, characterData: true });
        });
        viewport.scrollTop = 0;
        await changed;
        if (n - ordinal(first()) > 32) throw new Error("scroll skipped a transcript page");
        times.push(performance.now() - started);
      }
      if (first() !== dayOne || times.length === 0) throw new Error("scroll did not reach day one");
      times.sort((a, b) => a - b);
      return {
        older_pages: times.length,
        scroll_page_p95_ms: times[Math.floor(times.length * 0.95)],
      };
    },
    { dayOne },
  );
  console.log("terminal_history_scroll_600mib", JSON.stringify(scroll));
  await page.getByRole("button", { name: /jump to latest/i }).click();
  await page.getByText(newestText, { exact: true }).first().waitFor();

  await page.keyboard.press("Meta+f");
  const search = page.getByRole("searchbox");
  assert.ok(await search.evaluate((el) => el === document.activeElement), "Cmd-F focuses the search box");
  const started = performance.now();
  await search.fill(dayOne);
  await page.getByRole("button", { name: dayOne, exact: true }).click({ timeout: 180_000 });
  const original = page.locator("article").getByText(dayOne, { exact: true });
  await original.waitFor();
  assert.ok(
    await original.evaluate(
      (el) =>
        new Promise((resolve) => {
          const observer = new IntersectionObserver(([entry]) => {
            if (entry.isIntersecting) {
              observer.disconnect();
              clearTimeout(timer);
              resolve(true);
            }
          });
          const timer = setTimeout(() => {
            observer.disconnect();
            resolve(false);
          }, 5000);
          observer.observe(el);
        }),
    ),
    "opening the first day's match scrolls it onscreen",
  );
  console.log(
    "terminal_history_find_600mib",
    JSON.stringify({ query_to_day_one_visible_ms: performance.now() - started }),
  );
  if (evidence) await page.screenshot({ path: path.join(evidence, "terminal-history-day-one.png") });
  assert.deepEqual(errors, []);
  assert.ok(metrics.navigation_to_visible_ms < 200, "packed navigation through visible latest turn exceeded 200 ms");
} finally {
  await browser.close();
  await origin.stop(true);
}
