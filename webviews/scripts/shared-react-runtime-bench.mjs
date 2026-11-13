// Run via scripts/cmux-next/tests/shared-react-runtime-bench.sh on cmux-ci Linux.
// The browser uses the production trees. Fixtures replace host data, never application code.
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { appendFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { siteSettings, siteData, certificateChain } from "../src/browser-chrome/page-info/windowFixtures.ts";

const args = Object.fromEntries(
  Array.from({ length: (process.argv.length - 2) / 2 }, (_, i) => [
    process.argv[2 + i * 2].replace(/^--/, ""),
    process.argv[3 + i * 2],
  ]),
);
if (process.platform !== "linux" || !args.out || !args.baseline || !args.candidate)
  throw new Error("Linux only; --baseline SHA --candidate SHA --out DIR --samples N required");
const samples = Number(args.samples ?? 20);
if (!Number.isSafeInteger(samples) || samples < 1) throw new Error("Invalid sample count");
const output = path.resolve(args.out);
const json = (file, value) => writeFile(path.join(output, file), JSON.stringify(value, null, 2) + "\n");
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const roots = {
  pages: "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
  pane: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
  activity: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
  markdown: "Resources/markdown-viewer/webviews-app",
  inspector: "Native/OptChat/optchat-chief/inspector",
};
const pageNames = [
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
const surfaces = [
  ...pageNames.map((name) => ({ name, bundle: "pages" })),
  ...["pane", "markdown", "activity", "inspector"].map((name) => ({ name, bundle: name })),
];
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
};
const markdownText =
  "# Runtime benchmark\n\nProduction markdown with **bold text**.\n\n- [ ] Runtime unchecked task\n- [x] Runtime checked task\n";
const fixture = {
  path: "/benchmark/runtime.md",
  text: markdownText,
  hash: hash(markdownText),
  readOnly: false,
};

await mkdir(output, { recursive: true });
await mkdir(path.join(output, "diagnostics"), { recursive: true });
const variants = ["baseline", "candidate"];
const inventories = {};
async function inventory(directory, prefix = "") {
  const result = [];
  for (const item of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
    const relative = path.posix.join(prefix, item.name);
    if (item.isDirectory()) result.push(...(await inventory(path.join(directory, item.name), relative)));
    else if (item.isFile()) {
      const bytes = await readFile(path.join(directory, item.name));
      result.push({ path: relative, bytes: bytes.length, sha256: hash(bytes) });
    } else throw new Error(`Unexpected emitted non-file: ${relative}`);
  }
  return result;
}
for (const variant of variants) {
  const files = await inventory(path.join(output, variant, "bundles"));
  const bytes = (predicate) => files.filter(predicate).reduce((n, file) => n + file.bytes, 0);
  inventories[variant] = {
    source: args[variant],
    totalBytes: bytes(() => true),
    fileCount: files.length,
    // Runtime is a physical subdirectory of markdown, not an extra addition to totalBytes.
    sharedRuntimeBytes: bytes((file) => file.path.startsWith(`${roots.markdown}/__runtime/`)),
    surfaces: Object.fromEntries(
      Object.entries(roots).map(([name, directory]) => [name, bytes((file) => file.path.startsWith(`${directory}/`))]),
    ),
    files,
  };
  const emitted = (await readdir(path.join(output, variant, "bundles", roots.pages), { withFileTypes: true }))
    .filter((item) => item.isDirectory() && !item.name.startsWith("__"))
    .map((item) => item.name)
    .sort();
  if (JSON.stringify(emitted) !== JSON.stringify([...pageNames].sort()))
    throw new Error(`${variant}: expected exactly 37 Pages, found ${JSON.stringify(emitted)}`);
}
await json("tree-bytes.json", inventories);

const inspectorData = {
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
    note: "Runtime benchmark prompt",
    view: null,
    messages: [],
    system_parts: [],
    blocks: [],
  },
};
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
  ".woff": "font/woff",
};
const serverErrors = [];
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host}`);
    const [variant, name] = url.hostname.split(".");
    const surface = surfaces.find((entry) => entry.name === name);
    if (!variants.includes(variant) || !surface) {
      response.writeHead(404).end();
      return;
    }
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204).end();
      return;
    }
    if (surface.name === "inspector" && inspectorData[url.pathname]) {
      response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(inspectorData[url.pathname]));
      return;
    }
    // AgentPane's native snapshot endpoint exists even when no cached transcript is available.
    if (surface.name === "pane" && url.pathname === "/__snapshot/chat.js") {
      response.writeHead(200, { "Content-Type": "text/javascript" }).end("/* no cached transcript */");
      return;
    }
    if (url.pathname === "/__bench/react-probe.html") {
      response.writeHead(200, { "Content-Type": "text/html" }).end('<!doctype html><div id="probe"></div>');
      return;
    }
    let directory = roots[surface.bundle];
    let local = decodeURIComponent(url.pathname);
    if (local.startsWith("/__runtime/")) directory = roots.markdown;
    else if (surface.bundle === "pages" && !local.startsWith("/__shared/")) directory += `/${surface.name}`;
    if (local.endsWith("/")) local += surface.name === "markdown" ? "markdown-page.html" : "index.html";
    const base = path.resolve(output, variant, "bundles", directory);
    const file = path.resolve(base, `.${local}`);
    if (!file.startsWith(`${base}/`)) {
      response.writeHead(403).end();
      return;
    }
    const body = await readFile(file);
    const headers = {
      "Content-Type": mime[path.extname(file)] ?? "application/octet-stream",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "public, max-age=3600",
    };
    // Keep in-document policies, and mirror the shared native page host's resource policy.
    // The pane and activity documents carry their own more restrictive policy.
    if (surface.bundle === "pages" || surface.bundle === "markdown")
      headers["Content-Security-Policy"] =
        "default-src 'none'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; connect-src 'self'";
    response.writeHead(200, headers).end(body);
  } catch (error) {
    serverErrors.push({ url: request.url, host: request.headers.host, error: String(error) });
    response.writeHead(404).end("Missing production resource");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;

// Run inside the document from navigation start. Do not time the automation round trip.
function installGate({ name, state, markdown }) {
  window.__bench = { gate: null, readyMs: null, nativeCalls: [], markdownEdits: [] };
  if (state || name === "markdown")
    window.webkit = {
      messageHandlers: {
        cmuxPage: {
          async postMessage(message) {
            window.__bench.nativeCalls.push(message);
            if (message.t === "sub") {
              if (state && message.stream === `cmux.${name}.state`)
                queueMicrotask(() => window.__cmuxPageReceive({ t: "ev", sub: message.id, seq: 1, data: state }));
              return { t: "ok", id: message.id, value: { sub: message.id } };
            }
            let value = {};
            if (message.op === "cmux.markdown.config") value = markdown;
            if (message.op === "cmux.markdown.edited") window.__bench.markdownEdits.push(message.params);
            if (message.op === "cmux.markdown.save") value = { hash: markdown.hash };
            return { t: "ok", id: message.id, value };
          },
        },
      },
    };
  if (name === "pane")
    window.webkit = {
      messageHandlers: {
        agentSession: {
          async postMessage(message) {
            window.__bench.nativeCalls.push(message);
            return { ok: true, value: message.method === "ready" ? { protocolVersion: 1, transport: "mock" } : {} };
          },
        },
      },
    };
  if (name === "activity")
    window.webkit = {
      messageHandlers: {
        agentActivity: {
          async postMessage(message) {
            window.__bench.nativeCalls.push(message);
            return { ok: true, value: {} };
          },
        },
      },
    };
  const visible = (element) =>
    !!element &&
    element.getClientRects().length > 0 &&
    getComputedStyle(element).visibility !== "hidden" &&
    getComputedStyle(element).display !== "none";
  const enabled = (element) =>
    visible(element) && !element.disabled && element.getAttribute("aria-disabled") !== "true";
  const controls =
    'button,input:not([type="hidden"]),select,textarea,[role="button"],[role="switch"],a[href],[contenteditable="true"]';
  const any = (selector) => [...document.querySelectorAll(selector)].some(enabled);
  const check = () => {
    const root = document.querySelector("#root");
    const text = root?.innerText.trim() ?? "";
    let content = text.length >= 20 && !/^(loading|connecting)[.…\s]*$/i.test(text);
    let control = any(`#root ${controls.split(",").join(",#root ")}`);
    const busy = [...document.querySelectorAll('[aria-busy="true"],[role="progressbar"]')].some(visible);
    if (name === "settings") {
      content = any(
        ".settings .content [data-row-key] .row-control input,.settings .content [data-row-key] .row-control button,.settings .content [data-row-key] .row-control select",
      );
      control = any(".settings .sidebar input");
    } else if (name === "markdown") {
      content =
        text.includes("Runtime unchecked task") && document.querySelectorAll(".cmux-markdown-checkbox").length === 2;
      control = any('.ProseMirror[contenteditable="true"]');
    } else if (name === "pane") {
      content = text.length >= 20 && !!document.querySelector(".acpmux-shell");
      control = any('[contenteditable="true"],textarea');
    } else if (name === "inspector") {
      content = text.includes("Runtime benchmark prompt") && !!document.querySelector(".badges");
      control = any('select[aria-label="Turn"]');
    }
    const gate = {
      content,
      control,
      busy,
      text: text.slice(0, 400),
      controls: document.querySelectorAll(controls).length,
    };
    window.__bench.gate = gate;
    return content && control && !busy;
  };
  function tick() {
    if (!check()) {
      requestAnimationFrame(tick);
      return;
    }
    // Two frame boundaries and a post-frame task. Recheck after the paint opportunity;
    // this measures committed usable DOM, not page.load or merely a React mount.
    requestAnimationFrame(() =>
      requestAnimationFrame(() =>
        setTimeout(() => {
          if (check()) window.__bench.readyMs = performance.now();
          else requestAnimationFrame(tick);
        }, 0),
      ),
    );
  }
  requestAnimationFrame(tick);
}

const raw = [];
const runtimeProbes = [];
let browser;
let failed = false;
let fatalError = null;
try {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
  });
  await json("environment.json", {
    browser: browser.version(),
    browserExecutable: process.env.CMUX_CHROME_HEADLESS_SHELL ?? "system chrome",
    bun: process.versions.bun,
    node: process.versions.node,
    platform: process.platform,
    harnessSHA256: hash(await readFile(new URL(import.meta.url))),
    samples,
    cache:
      "fresh browser context for every navigation; HTTP and V8 browser process stay warm; OS disk cache uncontrolled",
    mounts:
      "isolated variant.surface.localhost origins; /__shared -> Pages; /__runtime -> app runtime; inspector standalone",
    endpoint:
      "visible content and enabled control, two rAF boundaries plus post-frame task; not native compositor presentation",
  });
  // One request sequence per page and variant; AB/BA order alternates every round.
  // Failure on either variant quarantines that surface after diagnostics, preventing 20 timeouts.
  const quarantine = new Set();
  for (let round = 0; round < samples; round++)
    for (const surface of surfaces) {
      if (quarantine.has(surface.name)) continue;
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
        page.on("pageerror", (error) => errors.push(`pageerror: ${error}`));
        page.on("requestfailed", (request) =>
          errors.push(`requestfailed: ${request.url()}: ${request.failure()?.errorText}`),
        );
        page.on("response", (response) => {
          requests.push({ url: response.url(), status: response.status() });
          if (response.status() >= 400) errors.push(`HTTP ${response.status()}: ${response.url()}`);
        });
        page.on("console", (message) => {
          if (["error", "warning"].includes(message.type())) consoleMessages.push(message.text());
        });
        const receipt = {
          variant,
          surface: surface.name,
          round,
          source: args[variant],
          readyMs: null,
          errors,
          requests,
          consoleMessages,
        };
        await page.addInitScript(installGate, {
          name: surface.name,
          state: hostStates[surface.name],
          markdown: fixture,
        });
        try {
          const fragment = surface.name === "server-cards" ? "#/pair-invite" : "";
          await page.goto(`http://${variant}.${surface.name}.localhost:${port}/?mock${fragment}`, {
            waitUntil: "commit",
            timeout: 30000,
          });
          await page.waitForFunction(() => typeof window.__bench?.readyMs === "number", null, { timeout: 15000 });
          receipt.readyMs = await page.evaluate(() => window.__bench.readyMs);
          receipt.gate = await page.evaluate(() => window.__bench.gate);
          if (surface.name === "markdown") {
            const task = page.locator(".cmux-markdown-checkbox").first();
            if (await task.evaluate((element) => element.classList.contains("is-checked")))
              throw new Error("Unchecked fixture rendered checked");
            await task.click();
            await page.waitForFunction(() =>
              document.querySelector(".cmux-markdown-checkbox")?.classList.contains("is-checked"),
            );
            receipt.taskCheckbox = "renderToStaticMarkup widget rendered and user click changed checked state";
          }
          if (errors.length) throw new Error("Browser/resource errors");
        } catch (error) {
          errors.push(String(error));
          failed = true;
          quarantine.add(surface.name);
          const prefix = `diagnostics/${variant}-${surface.name}-${round}`;
          receipt.gate = await page.evaluate(() => window.__bench).catch(() => null);
          await writeFile(path.join(output, `${prefix}.html`), await page.content().catch(() => "unavailable"));
          await page
            .screenshot({ path: path.join(output, `${prefix}.png`) })
            .catch((captureError) => errors.push(String(captureError)));
          receipt.diagnostics = prefix;
        } finally {
          raw.push(receipt);
          await appendFile(path.join(output, "samples.jsonl"), JSON.stringify(receipt) + "\n");
          console.log(JSON.stringify({ variant, surface: surface.name, round, readyMs: receipt.readyMs, errors }));
          await context.close();
        }
      }
    }
  for (const variant of variants) {
    if (!inventories[variant].sharedRuntimeBytes) {
      runtimeProbes.push({ variant, status: "not applicable", reason: "baseline has no shared runtime facade" });
      continue;
    }
    const context = await browser.newContext();
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(String(error)));
    try {
      await page.goto(`http://${variant}.markdown.localhost:${port}/__bench/react-probe.html`);
      const result = await page.evaluate(async () => {
        const [React, DOM, Client, JSX, Compiler] = await Promise.all([
          import("/__runtime/react.js"),
          import("/__runtime/react-dom.js"),
          import("/__runtime/react-dom-client.js"),
          import("/__runtime/react-jsx-runtime.js"),
          import("/__runtime/react-compiler-runtime.js"),
        ]);
        if (
          !React.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE ||
          !DOM.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE
        )
          throw new Error("Missing CJS interop internals");
        let update;
        function Probe() {
          const [value, setValue] = React.useState(0);
          update = setValue;
          const cache = Compiler.c(2);
          if (cache.length !== 2) throw new Error("Compiler memo hook failed");
          React.useEffect(() => {
            document.documentElement.dataset.probeEffect = "yes";
          }, []);
          return JSX.jsx("button", { children: `hook-${value}` });
        }
        const root = Client.createRoot(document.querySelector("#probe"));
        DOM.flushSync(() => root.render(JSX.jsx(Probe, {})));
        DOM.flushSync(() => update(1));
        if (document.querySelector("button")?.textContent !== "hook-1") throw new Error("Client hook update failed");
        const result = {
          reactVersion: React.version,
          compilerCache: true,
          stateUpdate: true,
          effect: document.documentElement.dataset.probeEffect === "yes",
        };
        root.unmount();
        if (!result.effect) throw new Error("Effect failed");
        return result;
      });
      if (errors.length) throw new Error(errors.join("; "));
      runtimeProbes.push({ variant, status: "passed", ...result });
    } catch (error) {
      failed = true;
      runtimeProbes.push({ variant, status: "failed", error: String(error), errors });
    } finally {
      await context.close();
    }
  }
} catch (error) {
  failed = true;
  fatalError = String(error);
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
  const percentile = (values, p) => (values.length ? values[Math.ceil(values.length * p) - 1] : null);
  const timing = surfaces.map(({ name }) => {
    const result = { surface: name };
    for (const variant of variants) {
      const rows = raw.filter((row) => row.variant === variant && row.surface === name);
      const values = rows
        .filter((row) => !row.errors.length && row.readyMs !== null)
        .map((row) => row.readyMs)
        .sort((a, b) => a - b);
      result[variant] = {
        n: values.length,
        failed: rows.length - values.length,
        p50Ms: percentile(values, 0.5),
        p95Ms: percentile(values, 0.95),
        maxMs: values.at(-1) ?? null,
        complete: values.length === samples,
      };
    }
    result.p95DeltaMs =
      result.baseline.complete && result.candidate.complete ? result.candidate.p95Ms - result.baseline.p95Ms : null;
    return result;
  });
  await json("summary.json", {
    status: failed ? "failed" : "completed",
    baseline: args.baseline,
    candidate: args.candidate,
    fatalError,
    bytes: {
      baseline: inventories.baseline.totalBytes,
      candidate: inventories.candidate.totalBytes,
      delta: inventories.candidate.totalBytes - inventories.baseline.totalBytes,
    },
    timing,
    runtimeProbes,
    serverErrors,
    gaps: [
      "Linux HTTP mount proxy does not prove native scheme-handler routing or CEF page-open timing.",
      "Inspector still bundles its own React; it is measured separately, never described as shared.",
      "Generic Pages gates prove visible content and an enabled control, not every page-specific interaction.",
      "Fresh contexts clear browser caches, not OS disk cache or browser-process code caches.",
      ...(samples < 20 ? ["Fewer than 20 samples: smoke run only; p95 is not acceptance evidence."] : []),
    ],
    unsupportedOrFailedSurfaces: timing
      .filter((row) => !row.baseline.complete || !row.candidate.complete)
      .map((row) => row.surface),
  });
}
if (failed) process.exitCode = 1;
