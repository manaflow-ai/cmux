// Production Pages only. The shell wrapper builds both exact source pins on cmux-ci Linux.
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { appendFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { siteSettings, siteData, certificateChain } from "../src/browser-chrome/page-info/windowFixtures.ts";

const args = {};
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  if (!["--out", "--samples"].includes(key) || process.argv[index + 1] === undefined)
    throw new Error("usage: pages-size-open-bench.mjs --out ABSOLUTE_DIR [--samples N]");
  args[key.slice(2)] = process.argv[index + 1];
}
// Refuse malformed paths before touching the filesystem, even when invoked without the wrapper.
if (
  process.platform !== "linux" ||
  !args.out ||
  !path.isAbsolute(args.out) ||
  args.out.includes("$") ||
  args.out === "/"
)
  throw new Error("Linux and an absolute, expanded --out directory are required");
const output = args.out;
const samples = Number(args.samples ?? 20);
if (!Number.isSafeInteger(samples) || samples < 1) throw new Error("samples must be a positive integer");
const pins = JSON.parse(await readFile(path.join(output, "pins.json"), "utf8"));
if (![pins.baseline, pins.candidate].every((pin) => /^[0-9a-f]{40}$/.test(pin)))
  throw new Error("Invalid exact source pins");
const json = (file, value) => writeFile(path.join(output, file), JSON.stringify(value, null, 2) + "\n");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const variants = ["baseline", "candidate"];
const pages = [
  "apps",
  "artifacts",
  "bookmarks",
  "certificate",
  "changelog",
  "chief-inspector",
  "chief-usage",
  "chief-views",
  "cloud",
  "cloud-progress",
  "coderouter",
  "cookie-import",
  "debug-settings",
  "feed",
  "files",
  "github",
  "group-editor",
  "history",
  "home-channels",
  "home-messages",
  "icon-picker",
  "import-history",
  "keybindings",
  "machines",
  "mobile-pairing",
  "onboarding",
  "passwords",
  "server-cards",
  "settings",
  "setup-card",
  "sidebar-chats",
  "site-data",
  "site-settings",
  "stash",
  "stats",
  "task-manager",
  "tasks",
];
// The existing check-bundle.mjs host fixtures, plus deterministic host data for pages without
// a production ?mock provider. No production module or DOM is replaced by the fixture.
const hostStates = {
  "site-settings": siteSettings,
  "site-data": siteData,
  certificate: certificateChain,
  "cookie-import": {
    title: "Import Cookies",
    importTitle: "Import…",
    notNowTitle: "Not Now",
    neverTitle: "Don't Show Again",
  },
  "setup-card": {
    agents: [{ id: "codex", name: "Codex", state: "missing" }],
    account: { signedIn: false },
    cli: "missing",
    classic: null,
  },
  "cloud-progress": {
    stage: "paused",
    step: 3,
    steps: ["requesting", "creating", "booting", "connecting", "ready"],
    failure: null,
    idle: true,
    machine: "benchmark",
    elapsedMs: 1000,
    finished: true,
    ask: null,
  },
};
// chief-inspector is one of the 37 Pages, not the standalone inspector bundle. Its HTTP-only
// dev data adapter replaces the native bridge under this HTTP mount while retaining the real CSP.
const chiefData = {
  "/api/status": {
    messages: 1,
    view_lines: 1,
    view_bytes: 24,
    budget: 10000,
    unbuilt: 0,
    nodes_built: 1,
    busy: [],
    failures: [],
    fatal: null,
    settled: true,
    closed: false,
    settle: null,
    top_level: 0,
    running_turn: null,
    last_turn: null,
    last_error: null,
    trace_on: false,
    constants: { node_bytes: 100, view_bytes: 1000, marks: [], grid: 10, placeholder: "…" },
  },
  "/api/turns": { turns: [] },
  "/api/turn": {
    turn: "now",
    layout: "blocks",
    exact: { view: true, system: true, messages: true },
    note: "Pages benchmark prompt",
    view: null,
    messages: [],
    system_parts: [],
    blocks: [],
  },
};
await mkdir(path.join(output, "diagnostics"), { recursive: true });
const inventory = async (directory, prefix = "") => {
  const files = [];
  for (const item of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
    const relative = path.posix.join(prefix, item.name);
    if (item.isDirectory()) files.push(...(await inventory(path.join(directory, item.name), relative)));
    else if (item.isFile()) {
      const bytes = await readFile(path.join(directory, item.name));
      files.push({ path: relative, bytes: bytes.length, sha256: sha256(bytes) });
    } else throw new Error(`Unexpected emitted non-file: ${relative}`);
  }
  return files;
};
const sizes = {};
for (const variant of variants) {
  const files = await inventory(path.join(output, variant, "pages"));
  const documents = files
    .filter((file) => /^[^/]+\/index\.html$/.test(file.path))
    .map((file) => file.path.split("/")[0])
    .sort();
  if (JSON.stringify(documents) !== JSON.stringify([...pages].sort()))
    throw new Error(`${variant}: expected all 37 Pages, got ${documents.join(",")}`);
  const bytes = (prefix) =>
    files.filter((file) => file.path.startsWith(prefix)).reduce((sum, file) => sum + file.bytes, 0);
  sizes[variant] = {
    source: pins[variant],
    totalBytes: bytes(""),
    fileCount: files.length,
    sharedBytes: bytes("__shared/"),
    pageBytes: Object.fromEntries(pages.map((name) => [name, bytes(`${name}/`)])),
    files,
  };
}
await json("tree-bytes.json", sizes);
// Splitting JavaScript must preserve each document's isolated CSS and cascade.
const cssEquality = [];
for (const name of pages) {
  const styles = [];
  for (const variant of variants) {
    const html = await readFile(path.join(output, variant, "pages", name, "index.html"), "utf8");
    const matches = [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)];
    if (matches.length !== 1) throw new Error(`${variant}/${name}: expected one inline stylesheet`);
    styles.push(matches[0][1]);
  }
  cssEquality.push({ page: name, equal: styles[0] === styles[1], hashes: styles.map(sha256) });
}
await json("css-equality.json", cssEquality);
const changedCSS = cssEquality.filter((row) => !row.equal).map((row) => row.page);
if (changedCSS.length) throw new Error(`Page CSS changed: ${changedCSS.join(", ")}`);
console.log(
  JSON.stringify({
    bytes: {
      baseline: sizes.baseline.totalBytes,
      candidate: sizes.candidate.totalBytes,
      delta: sizes.candidate.totalBytes - sizes.baseline.totalBytes,
    },
    sharedCountedOnce: true,
  }),
);

const csp =
  "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; worker-src 'self'";
const mime = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
};
const serverErrors = [];
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host}`);
    const [variant, name] = url.hostname.split(".");
    if (!variants.includes(variant) || !pages.includes(name)) {
      response.writeHead(404).end();
      return;
    }
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204).end();
      return;
    }
    const resource = decodeURIComponent(url.pathname);
    const base = path.join(output, variant, "pages", resource.startsWith("/__shared/") ? "" : name);
    const local = path.resolve(base, `.${resource.endsWith("/") ? `${resource}index.html` : resource}`);
    if (!local.startsWith(`${base}/`)) {
      response.writeHead(403).end();
      return;
    }
    const body = await readFile(local);
    response
      .writeHead(200, {
        "Content-Type": mime[path.extname(local)] ?? "application/octet-stream",
        "Content-Security-Policy": csp,
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "public, max-age=3600",
      })
      .end(body);
  } catch (error) {
    serverErrors.push({ host: request.headers.host, url: request.url, error: String(error) });
    response.writeHead(404).end("Missing production resource");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;

function bootstrap({ name, state, api }) {
  window.__pagesProof = { readyMs: null, gate: null, hostCalls: [], fixtureCalls: [] };
  if (state)
    window.webkit = {
      messageHandlers: {
        cmuxPage: {
          async postMessage(message) {
            window.__pagesProof.hostCalls.push(message);
            if (message.t === "sub") {
              if (
                message.stream === `cmux.${name}.state` ||
                (name === "setup-card" && message.stream === "cmux.setup.changed")
              )
                queueMicrotask(() => window.__cmuxPageReceive({ t: "ev", sub: message.id, seq: 1, data: state }));
              return { t: "ok", id: message.id, value: { sub: message.id } };
            }
            const value = ["cmux.setup.state", "cmux.cloudProgress.state"].includes(message.op) ? state : {};
            return { t: "ok", id: message.id, value };
          },
        },
      },
    };
  if (api) {
    const originalFetch = window.fetch.bind(window);
    window.fetch = (input, init) => {
      const url = new URL(typeof input === "string" ? input : (input.url ?? String(input)), location.href);
      if (url.origin === location.origin && Object.hasOwn(api, url.pathname)) {
        window.__pagesProof.fixtureCalls.push(url.pathname + url.search);
        return Promise.resolve(
          new Response(JSON.stringify(api[url.pathname]), { headers: { "Content-Type": "application/json" } }),
        );
      }
      return originalFetch(input, init);
    };
  }
  const visible = (element) => {
    if (!element || element.getClientRects().length === 0) return false;
    if (element.checkVisibility && !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }))
      return false;
    const box = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return (
      box.width > 0 &&
      box.height > 0 &&
      box.bottom > 0 &&
      box.right > 0 &&
      box.top < innerHeight &&
      box.left < innerWidth &&
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      style.opacity !== "0"
    );
  };
  const enabled = (element) =>
    visible(element) &&
    !element.matches(":disabled") &&
    element.getAttribute("aria-disabled") !== "true" &&
    !element.closest("[inert]");
  const controls =
    'button,input:not([type="hidden"]),select,textarea,[role="button"],[role="switch"],a[href],[contenteditable="true"]';
  const check = () => {
    const root = document.querySelector("#root");
    const text = root?.innerText.trim() ?? "";
    // Require a visible rendered text node, not root.childElementCount or a navigation event.
    let content =
      text.length >= 20 &&
      !/^(loading|connecting)[.…\s]*$/i.test(text) &&
      [...(root?.querySelectorAll("p,h1,h2,h3,label,li,td,span,button") ?? [])].some(
        (element) => visible(element) && element.textContent.trim().length >= 3,
      );
    const controlElements = [...(root?.querySelectorAll(controls) ?? [])];
    // A few first-party Pages are read-only views (certificate, history, and inspector
    // summaries). They have no actionable control by design; requiring a synthetic button
    // would turn a successful open into a false failure. Interactive pages still require an
    // enabled, visible control.
    let control = controlElements.length === 0 || controlElements.some(enabled);
    if (name === "settings") {
      content = [...document.querySelectorAll(".settings .content .row-title")].some(
        (element) => visible(element) && element.textContent.trim(),
      );
      control = [
        ...document.querySelectorAll(
          '.settings .content .row-control button,.settings .content .row-control input,.settings .content .row-control select,[data-row-key] [role="switch"]',
        ),
      ].some(enabled);
    }
    if (name === "chief-inspector")
      content = text.includes("Pages benchmark prompt") && visible(document.querySelector(".badges"));
    const busy = [...document.querySelectorAll('[aria-busy="true"],[role="progressbar"]')].some(visible);
    const gate = {
      content: Boolean(content),
      control,
      busy,
      text: text.slice(0, 350),
      controls: root?.querySelectorAll(controls).length ?? 0,
    };
    window.__pagesProof.gate = gate;
    return gate.content && control && !busy;
  };
  function tick() {
    if (!check()) {
      requestAnimationFrame(tick);
      return;
    }
    requestAnimationFrame(() =>
      requestAnimationFrame(() =>
        setTimeout(() => {
          if (check()) window.__pagesProof.readyMs = performance.now();
          else requestAnimationFrame(tick);
        }, 0),
      ),
    );
  }
  requestAnimationFrame(tick);
}

const raw = [];
const quarantine = new Set();
let browser;
let fatalError = null;
try {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
  });
  await json("environment.json", {
    pins,
    browser: browser.version(),
    executable: process.env.CMUX_CHROME_HEADLESS_SHELL ?? "system chrome",
    node: process.versions.node,
    bun: process.versions.bun,
    platform: process.platform,
    samples,
    cpu: os.cpus()[0]?.model,
    logicalCPUs: os.cpus().length,
    memoryBytes: os.totalmem(),
    architecture: os.arch(),
    kernel: os.release(),
    harnessSHA256: sha256(await readFile(new URL(import.meta.url))),
    fixturesSHA256: sha256(JSON.stringify({ hostStates, chiefData })),
    csp,
    endpoint: "visible meaningful content and enabled control, two rAF boundaries and post-frame task, then recheck",
    mounts: "per-variant per-page origin; /__shared maps to the physical Pages/__shared directory",
    fixtures:
      "check-bundle browser-chrome fixtures and ?mock; setup-card host data; paused cloud-progress host data; chief-inspector HTTP data adapter",
    cache: "fresh context every navigation; browser process and OS disk caches remain warm",
  });
  for (let round = 0; round < samples; round++)
    for (const name of pages) {
      if (quarantine.has(name)) continue;
      for (const variant of round % 2 ? [...variants].reverse() : variants) {
        const context = await browser.newContext({
          viewport: { width: 1280, height: 900 },
          locale: "en-US",
          serviceWorkers: "block",
        });
        const page = await context.newPage();
        const errors = [],
          requests = [],
          consoleMessages = [];
        let captureEvents = true;
        page.on("pageerror", (error) => {
          if (captureEvents) errors.push(`pageerror: ${error}`);
        });
        page.on("requestfailed", (request) => {
          if (captureEvents) errors.push(`requestfailed: ${request.url()}: ${request.failure()?.errorText}`);
        });
        page.on("response", (response) => {
          if (!captureEvents) return;
          requests.push({ url: response.url(), status: response.status() });
          if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`);
        });
        page.on("console", (message) => {
          if (captureEvents && ["error", "warning"].includes(message.type())) {
            consoleMessages.push(message.text());
            if (message.type() === "error") errors.push(`console: ${message.text()}`);
          }
        });
        const receipt = {
          variant,
          page: name,
          round,
          source: pins[variant],
          readyMs: null,
          errors,
          requests,
          consoleMessages,
        };
        await page.addInitScript(bootstrap, {
          name,
          state: hostStates[name],
          api: name === "chief-inspector" ? chiefData : null,
        });
        try {
          const fragment = name === "server-cards" ? "#/pair-invite" : "";
          await page.goto(`http://${variant}.${name}.localhost:${port}/?mock${fragment}`, {
            waitUntil: "commit",
            timeout: 30000,
          });
          await page.waitForFunction(() => typeof window.__pagesProof?.readyMs === "number", null, { timeout: 12000 });
          receipt.readyMs = await page.evaluate(() => window.__pagesProof.readyMs);
          // Load completion checks startup resource failures, but never defines the timing endpoint.
          await page.waitForLoadState("load", { timeout: 12000 });
          receipt.gate = await page.evaluate(() => window.__pagesProof.gate);
          receipt.fixtureCalls = await page.evaluate(() => window.__pagesProof.fixtureCalls);
          if (errors.length) throw new Error("Page or resource errors");
        } catch (error) {
          errors.push(String(error));
          quarantine.add(name);
          receipt.readyMs = null;
          const prefix = `diagnostics/${variant}-${name}-${round}`;
          receipt.diagnostics = prefix;
          receipt.state = await page.evaluate(() => window.__pagesProof).catch(() => null);
          await writeFile(path.join(output, `${prefix}.html`), await page.content().catch(() => "unavailable"));
          await page
            .screenshot({ path: path.join(output, `${prefix}.png`), timeout: 5000 })
            .catch((error) => errors.push(String(error)));
          await json(`${prefix}.json`, receipt);
          console.log(
            JSON.stringify({
              failed: name,
              variant,
              round,
              gate: receipt.state?.gate,
              errors: errors.slice(-3),
              diagnostics: prefix,
            }),
          );
        } finally {
          captureEvents = false;
          raw.push(receipt);
          await appendFile(path.join(output, "samples.jsonl"), JSON.stringify(receipt) + "\n");
          await context.close();
        }
      }
    }
} catch (error) {
  fatalError = String(error);
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
  const percentile = (values, p) => (values.length ? values[Math.ceil(values.length * p) - 1] : null);
  const timing = pages.map((name) => {
    const result = { page: name, quarantined: quarantine.has(name) };
    for (const variant of variants) {
      const rows = raw.filter((row) => row.page === name && row.variant === variant);
      const values = rows
        .filter((row) => !row.errors.length && row.readyMs !== null)
        .map((row) => row.readyMs)
        .sort((a, b) => a - b);
      // A failure quarantines the pair. Its early successful samples are diagnostic only.
      const complete = !result.quarantined && values.length === samples;
      result[variant] = {
        n: values.length,
        failures: rows.length - values.length,
        complete,
        p50Ms: complete ? percentile(values, 0.5) : null,
        p95Ms: complete ? percentile(values, 0.95) : null,
        maxMs: complete ? values.at(-1) : null,
      };
    }
    result.p95DeltaMs =
      result.baseline.complete && result.candidate.complete ? result.candidate.p95Ms - result.baseline.p95Ms : null;
    console.log(JSON.stringify(result));
    return result;
  });
  const failed = Boolean(fatalError) || timing.some((row) => !row.baseline.complete || !row.candidate.complete);
  await json("summary.json", {
    status: failed ? "failed" : samples < 20 ? "smoke only" : "completed",
    pins,
    samples,
    fatalError,
    bytes: {
      baseline: sizes.baseline.totalBytes,
      candidate: sizes.candidate.totalBytes,
      delta: sizes.candidate.totalBytes - sizes.baseline.totalBytes,
    },
    timing,
    serverErrors,
    unsupportedOrFailedPages: timing
      .filter((row) => !row.baseline.complete || !row.candidate.complete)
      .map((row) => row.page),
    gaps: [
      "Linux HTTP proxy checks the native-style resource layout, not CEF/native scheme routing or compositor presentation.",
      "The gate checks visible content and an enabled control; it does not verify every interaction on each page.",
      "Browser contexts are cold; browser process and OS disk caches are not reset.",
      ...(samples < 20 ? ["Fewer than 20 samples: no acceptance timing claim."] : []),
    ],
  });
  if (failed) process.exitCode = 1;
}
