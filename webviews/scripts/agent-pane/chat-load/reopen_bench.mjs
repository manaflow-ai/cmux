// l10n-allow-file: a benchmark harness, never shown to a user.
// Reopen benchmark: an app restart onto a long saved chat, with the acpmux daemon already running
// in the background and the machine under load. Leo, 2026-11-05: "it takes, like, 30 seconds to
// load this particular chat ... did you test it under load? Did you test it under contention? ...
// did you test it while there is a daemon that is already in the background that's running?"
//
// The shipped pane bundle (scripts/cmux-next/build-agent-pane-web.sh --out DIR), served over
// loopback in headless Chromium, opens the fixture's long chat (fixture.ts) from a real acpmux
// daemon this harness starts once and keeps running. Each round is an app restart: a fresh browser
// context (no page memory, no HTTP cache), whose host stub answers as the app's host does after a
// relaunch:
//   chat.scrollAnchor.get  the reading place the previous page saved (a warm-up page scrolls
//                          --up-viewports up the chat and leaves it there, as a reader did);
//   chat.tail.get          --host-tail none: nothing (feat-cmux-next before #this: the host's tail
//                          tier is memory only and a relaunch forgets it); saved: the tail the
//                          warm-up page handed the host (`chat.tail`), as a host that keeps local
//                          tails across a relaunch answers.
// While it opens, --load-pages other pages open other fixture chats against the same daemon (the
// restored tabs of a 31-100-tab window) and --burn processes spin on every core (CPU contention).
//
// Per round, on the page clock from navigation start:
//   first_rows_ms   the first frame that shows transcript rows (the transcript not hidden);
//   placed_ms       the first frame that shows the saved reading place's row (or, with no place,
//                   the newest message);
//   settled_ms      the end of the last shift, long task or hide before 1500 ms of none;
//   shift_px        how far painted rows moved under the reader after first_rows_ms, summed (the
//                   top visible row's movement in the scroller between frames, with no input);
//   shifts          frames with such a movement over 1 px;
//   hides           times the transcript went hidden again after it showed;
//   cls             Chromium's layout-shift sum after first_rows_ms;
//   long_max_ms     the longest main-thread task (>50 ms) or frame gap of the load.
// Results: every round, and p50/p95/max of each number, in --out (JSON) and on stdout.
//
//   node reopen_bench.mjs --pane DIR --fixture FIXTURE_JSON --acpmux BIN --out OUT_JSON
//        [--target 0] [--rounds 10] [--load-pages 30] [--burn N] [--up-viewports 40]
//        [--host-tail none|saved] [--daemon warm|restart] [--port 4319] [--ws-port 47931]
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import pw from "playwright";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const paneDir = path.resolve(arg("pane"));
const fixture = JSON.parse(fs.readFileSync(arg("fixture"), "utf8"));
const acpmux = path.resolve(arg("acpmux"));
const out = arg("out", "reopen.json");
const target = fixture.sessions[Number(arg("target", "0"))];
const rounds = Number(arg("rounds", "10"));
const loadPages = Number(arg("load-pages", "30"));
const burn = Number(arg("burn", String(os.cpus().length)));
const upViewports = Number(arg("up-viewports", "40"));
const hostTail = arg("host-tail", "none");
const daemonMode = arg("daemon", "warm");
const port = Number(arg("port", "4319"));
const wsPort = Number(arg("ws-port", "47931"));
if (!["none", "saved"].includes(hostTail)) throw new Error("--host-tail is none or saved");
if (!["warm", "restart"].includes(daemonMode)) throw new Error("--daemon is warm or restart");
const others = fixture.sessions.filter((s) => s.id !== target.id);

// ---- The daemon: started once and kept running (warm), or started fresh for each round (restart).
const token = crypto.randomBytes(24).toString("hex");
const origin = `http://127.0.0.1:${port}`;
const endpoint = `ws://127.0.0.1:${wsPort}`;
const home = fixture.home;
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "reopen-daemon-"));
fs.writeFileSync(
  path.join(home, "config.json"),
  JSON.stringify({ harnesses: { fc: { kind: "claude-stdio", argv: ["false"] } }, defaultHarness: "fc" }),
  { mode: 0o600 },
);
fs.mkdirSync(path.join(scratch, "uhome"), { recursive: true });
let daemon;
const waitPort = async (deadline) => {
  for (;;) {
    const open = await new Promise((resolve) => {
      const socket = net.connect(wsPort, "127.0.0.1", () => (socket.destroy(), resolve(true)));
      socket.on("error", () => resolve(false));
    });
    if (open) return;
    if (Date.now() > deadline) throw new Error("acpmux did not listen");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};
const startDaemon = async () => {
  daemon = spawn(
    acpmux,
    [
      "daemon",
      "run",
      "--log",
      "warn",
      "--listen",
      `127.0.0.1:${wsPort}`,
      "--token",
      token,
      "--allow-dev-origin",
      origin,
      "--dev",
    ],
    {
      env: {
        HOME: path.join(scratch, "uhome"),
        PATH: "/usr/bin:/bin",
        ACPMUX_HOME: home,
        ACPMUX_SOCKET: path.join(scratch, "s.sock"),
        TMPDIR: scratch,
        RUST_LOG: "warn",
      },
      stdio: [
        "ignore",
        fs.openSync(path.join(scratch, "daemon.out"), "a"),
        fs.openSync(path.join(scratch, "daemon.out"), "a"),
      ],
    },
  );
  await waitPort(Date.now() + 60_000);
};
const stopDaemon = async () => {
  if (!daemon || daemon.exitCode !== null) return;
  const exited = new Promise((resolve) => daemon.once("exit", resolve));
  daemon.kill("SIGTERM");
  await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 10_000))]);
  if (daemon.exitCode === null) daemon.kill("SIGKILL");
};

// ---- CPU contention: processes this harness starts and stops itself (their pids only).
let burners = [];
const startBurn = () => {
  burners = Array.from({ length: burn }, () => spawn(process.execPath, ["-e", "for(;;){}"], { stdio: "ignore" }));
};
const stopBurn = () => {
  for (const child of burners) child.kill("SIGKILL");
  burners = [];
};

// ---- The pane, served as the browser dev slot serves it.
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const file = path.join(paneDir, decodeURIComponent(url.pathname === "/" ? "/index.html" : url.pathname));
  if (!file.startsWith(paneDir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] ?? "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));

// Before any pane script: the app host's replies after a relaunch, and the frame probe.
function shim(config) {
  const probe = (window.__reopen = {
    anchorWrites: [],
    hostTail: undefined,
    firstRows: undefined,
    placed: undefined,
    lastChange: 0,
    shiftPx: 0,
    shifts: 0,
    hides: 0,
    cls: 0,
    longTasks: [],
    trace: [],
  });
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        probe.longTasks.push([entry.startTime, entry.duration]);
        if (probe.firstRows !== undefined)
          probe.lastChange = Math.max(probe.lastChange, entry.startTime + entry.duration);
      }
    }).observe({ type: "longtask", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries())
        if (probe.firstRows !== undefined && entry.startTime >= probe.firstRows && !entry.hadRecentInput)
          probe.cls += entry.value;
    }).observe({ type: "layout-shift", buffered: true });
  } catch {
    // Chromium only.
  }
  let last = 0;
  let shown = false;
  let top; // [rowId, px from the scroller's top] of the top visible row in the last frame
  let lastGeometry;
  const frame = (now) => {
    if (last && now - last > 50) probe.longTasks.push([last, now - last]);
    last = now;
    const scroller = document.querySelector(".acpmux-scroll");
    const hidden =
      !scroller ||
      scroller.closest("[data-seeking]") !== null ||
      getComputedStyle(scroller).visibility === "hidden" ||
      scroller.clientHeight === 0;
    const box = scroller?.getBoundingClientRect();
    const geometry = scroller
      ? {
          top: Math.round(scroller.scrollTop),
          height: scroller.scrollHeight,
          client: scroller.clientHeight,
          dock: getComputedStyle(scroller).getPropertyValue("--acpmux-dock-space").trim(),
          rows: scroller.querySelectorAll("[data-row-id]").length,
          first: scroller.querySelector("[data-row-id]")?.getAttribute("data-row-id"),
          // The bottom stack's parts two levels down, as class:height: what grew under the rows.
          dockParts: [...document.querySelectorAll(".acpmux-dock > *, .acpmux-dock > * > *")]
            .map(
              (el) =>
                `${String(el.className).split(" ")[0] || el.tagName}:${Math.round(el.getBoundingClientRect().height)}`,
            )
            .join(" "),
        }
      : undefined;
    let visible;
    if (!hidden) {
      for (const row of scroller.querySelectorAll("[data-row-id]")) {
        const r = row.getBoundingClientRect();
        if (r.bottom > box.top + 1 && r.top < box.bottom && r.height > 0) {
          visible = [row.getAttribute("data-row-id"), r.top - box.top];
          break;
        }
      }
    }
    if (visible && probe.firstRows === undefined) {
      probe.firstRows = now;
      probe.lastChange = now;
    }
    if (shown && hidden) {
      probe.hides += 1;
      probe.lastChange = now;
      probe.trace.push(["hide", Math.round(now)]);
    }
    shown = !!visible;
    if (visible && top) {
      const row = scroller.querySelector(`[data-row-id="${CSS.escape(top[0])}"]`);
      if (row) {
        const moved = Math.abs(row.getBoundingClientRect().top - box.top - top[1]);
        if (moved > 1) {
          probe.shiftPx += moved;
          probe.shifts += 1;
          probe.lastChange = now;
          if (probe.trace.length < 200)
            probe.trace.push([
              "shift",
              Math.round(now),
              Math.round(moved),
              top[0],
              // What moved it: the scroller's own geometry against the frame before.
              { ...geometry, was: lastGeometry },
            ]);
        }
      } else {
        // The row the reader saw is gone from the DOM: the view jumped to other rows.
        probe.shifts += 1;
        probe.shiftPx += scroller.clientHeight;
        probe.lastChange = now;
        if (probe.trace.length < 200) probe.trace.push(["jump", Math.round(now)]);
      }
    }
    if (visible && probe.placed === undefined) {
      // The saved place's row, or the newest message: a place older than what the pane holds
      // opens at the latest message.
      const want = config.anchor?.rowId;
      if (
        (want && scroller.querySelector(`[data-row-id="${CSS.escape(want)}"]`)) ||
        scroller.textContent.includes(config.marker)
      )
        probe.placed = now;
    }
    top = visible;
    lastGeometry = geometry;
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  const reply = (request) => {
    const method = String(request.method).replace(/^cmux\.agent\./, "");
    const params = request.params ?? {};
    switch (method) {
      case "handshake":
      case "ready":
        return {
          ok: true,
          value: {
            protocolVersion: 1,
            transport: "acpmux-websocket",
            endpoint: config.endpoint,
            token: config.token,
            sessionId: config.sessionId,
            cwd: "/tmp",
            linkScheme: "cmux-dev",
          },
        };
      case "acp.trust.get":
        return { ok: true, value: { cwd: params.cwd ?? "/tmp", level: "trusted" } };
      case "pane.context":
        return { ok: true, value: { cwd: "/tmp", urls: [] } };
      case "chat.scrollAnchor":
        if (params.sessionId === config.sessionId)
          probe.anchorWrites.push({ rowId: params.rowId, offset: params.offset });
        return { ok: true, value: null };
      case "chat.scrollAnchor.get":
        return { ok: true, value: params.sessionId === config.sessionId ? (config.anchor ?? null) : null };
      case "chat.tail":
        if (params.sessionId === config.sessionId && params.tail) probe.hostTail = params.tail;
        return { ok: true, value: null };
      case "chat.tail.get":
        return { ok: true, value: params.sessionId === config.sessionId ? (config.hostTail ?? null) : null };
      default:
        return { ok: true, value: null };
    }
  };
  window.webkit = {
    messageHandlers: {
      agentSession: {
        // A stand-in, as the gallery's: the flicker detector (acpmux/flickerLog.ts) stays off. It calls
        // setTimeout unbound, which only WebKit (where this handler lives in the app) allows.
        standIn: true,
        postMessage: (request) => Promise.resolve(reply(request)),
      },
    },
  };
}

const browser = await pw.chromium.launch({ channel: "chrome" }).catch(() => pw.chromium.launch());
const consoleLines = [];
const open = async (sessionId, extra = {}) => {
  const context = await browser.newContext({ bypassCSP: true, viewport: { width: 1100, height: 900 } });
  const page = await context.newPage();
  if (sessionId === target.id)
    page.on(
      "console",
      (message) => consoleLines.length < 400 && consoleLines.push(`${message.type()}: ${message.text()}`.slice(0, 400)),
    );
  await page.addInitScript(shim, { endpoint, token, sessionId, ...extra });
  await page.goto(`${origin}/index.html`);
  return { context, page };
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- Warm-up: the reader's last visit. It opens the chat, scrolls --up-viewports up, rests, and
// leaves the reading place and the tail the host was handed.
await startDaemon();
let anchor = null;
let savedTail = null;
{
  const { context, page } = await open(target.id, { marker: target.lastMarker });
  try {
    await page.waitForFunction(() => window.__reopen.placed !== undefined, null, { timeout: 90_000 });
  } catch (error) {
    const dom = await page.evaluate(() => ({
      probe: { ...window.__reopen, hostTail: undefined, trace: undefined, longTasks: window.__reopen.longTasks.length },
      hostTailEvents: window.__reopen.hostTail?.events?.length ?? 0,
      scroller: !!document.querySelector(".acpmux-scroll"),
      scrollerBox: (() => {
        const el = document.querySelector(".acpmux-scroll");
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return {
          top: r.top,
          height: r.height,
          client: el.clientHeight,
          scrollTop: el.scrollTop,
          scrollHeight: el.scrollHeight,
          visibility: getComputedStyle(el).visibility,
          rowsInside: el.querySelectorAll("[data-row-id]").length,
          firstRowIds: [...el.querySelectorAll("[data-row-id]")]
            .slice(-5)
            .map((row) => [
              row.getAttribute("data-row-id"),
              Math.round(row.getBoundingClientRect().top),
              Math.round(row.getBoundingClientRect().height),
            ]),
        };
      })(),
      rows: document.querySelectorAll("[data-row-id]").length,
      hasMarker: document.body.innerText.includes(window.__reopen && "Done with turn"),
      seeking: !!document.querySelector("[data-seeking]"),
      text: document.body.innerText.slice(-800),
    }));
    console.error(JSON.stringify({ warmup: "timeout", dom }));
    console.error(
      consoleLines
        .slice(-60)
        .map((line) => line.slice(0, 300))
        .join("\n"),
    );
    console.error(fs.readFileSync(path.join(scratch, "daemon.out"), "utf8").slice(-4000));
    throw error;
  }
  for (let i = 0; i < upViewports; i += 1) {
    await page.evaluate(() => {
      const scroller = document.querySelector(".acpmux-scroll");
      scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight);
      scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -scroller.clientHeight, bubbles: true }));
    });
    await sleep(150);
  }
  await sleep(2000);
  ({ anchor, savedTail } = await page.evaluate(() => ({
    anchor: window.__reopen.anchorWrites.at(-1) ?? null,
    savedTail: window.__reopen.hostTail ?? null,
  })));
  await context.close();
}
console.log(JSON.stringify({ anchor, savedTailEvents: savedTail?.events?.length ?? 0 }));
if (upViewports > 0 && !anchor?.rowId) throw new Error("the warm-up page saved no reading place");

// ---- Rounds.
const rows = [];
for (let round = 0; round < rounds; round += 1) {
  if (daemonMode === "restart") {
    await stopDaemon();
    await startDaemon();
  }
  startBurn();
  const load = Promise.all(
    Array.from({ length: Math.min(loadPages, others.length) }, (_, i) => open(others[i % others.length].id, {})),
  );
  const t0 = Date.now();
  const { context, page } = await open(target.id, {
    marker: target.lastMarker,
    anchor: anchor?.rowId ? anchor : null,
    hostTail: hostTail === "saved" ? savedTail : null,
  });
  let state;
  for (;;) {
    state = await page.evaluate(() => {
      const p = window.__reopen;
      return { ...p, now: performance.now(), trace: p.trace.slice(0, 60) };
    });
    const longEnd = state.longTasks.reduce((end, [start, d]) => Math.max(end, start + d), 0);
    const quiet = state.now - Math.max(state.lastChange, state.firstRows !== undefined ? longEnd : 0);
    if (state.firstRows !== undefined && state.placed !== undefined && quiet >= 1500) break;
    if (Date.now() - t0 > 120_000) {
      state.timedOut = true;
      break;
    }
    await sleep(100);
  }
  const loaded = await load;
  stopBurn();
  const settled = Math.max(state.lastChange, state.firstRows ?? 0, state.placed ?? 0);
  const row = {
    round,
    first_rows_ms: state.firstRows === undefined ? null : Math.round(state.firstRows),
    placed_ms: state.placed === undefined ? null : Math.round(state.placed),
    settled_ms: Math.round(settled),
    shift_px: Math.round(state.shiftPx),
    shifts: state.shifts,
    hides: state.hides,
    cls: Math.round(state.cls * 1000) / 1000,
    long_max_ms: Math.round(state.longTasks.reduce((m, [, d]) => Math.max(m, d), 0)),
    timed_out: !!state.timedOut,
    trace: state.trace,
  };
  rows.push(row);
  console.log(JSON.stringify(row));
  await context.close();
  await Promise.all(loaded.map(({ context: c }) => c.close()));
}

const pct = (values, p) => {
  const v = values.filter((x) => typeof x === "number").sort((a, b) => a - b);
  return v.length ? v[Math.min(v.length - 1, Math.ceil((p / 100) * v.length) - 1)] : null;
};
const keys = ["first_rows_ms", "placed_ms", "settled_ms", "shift_px", "shifts", "hides", "cls", "long_max_ms"];
const summary = Object.fromEntries(
  keys.map((k) => [
    k,
    {
      p50: pct(
        rows.map((r) => r[k]),
        50,
      ),
      p95: pct(
        rows.map((r) => r[k]),
        95,
      ),
      max: pct(
        rows.map((r) => r[k]),
        100,
      ),
    },
  ]),
);
const result = {
  bench: "reopen",
  host: os.hostname(),
  cores: os.cpus().length,
  target: { id: target.id, turns: target.turns, records: target.records, bytes: target.bytes },
  config: { rounds, loadPages, burn, upViewports, hostTail, daemonMode },
  anchor,
  summary,
  timed_out: rows.filter((r) => r.timed_out).length,
  rows,
};
fs.writeFileSync(out, JSON.stringify(result, null, 2));
console.log(JSON.stringify({ summary, timed_out: result.timed_out }));
await browser.close();
server.close();
await stopDaemon();
process.exit(0);
