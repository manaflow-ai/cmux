// Usability timings of the agent pane against a live dev slot (dev-slot.sh), headless Chromium:
// reopening a stored session, its first prompt (respawn + session/load), a model switch, an
// interrupt, an unavailable harness, and (with --restart-cmd) recovery after a daemon restart.
//
//   bun scripts/agent-pane/bench-usability.mjs --url "<agent pane URL>" [--restart-cmd "<shell>"] [--out FILE]
import { execSync } from "node:child_process";
import fs from "node:fs";
import { chromium } from "playwright";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const url = arg("url");
const restartCmd = arg("restart-cmd");
const out = arg("out");
const report = {};
const log = (key, value) => {
  report[key] = value;
  console.log(key.padEnd(34), typeof value === "number" ? `${value.toFixed(0)} ms` : JSON.stringify(value));
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 760 } });
const t = () => page.evaluate(() => performance.now());
const state = () => page.evaluate(() => window.cmuxAcpmuxDebug.chatState());
const waitFor = (fn, arg, timeout = 120_000) => page.waitForFunction(fn, arg, { timeout, polling: "raf" });

// 1. Cold open of a new chat: first paint, composer in the DOM, then a usable session.
await page.goto(url.includes("&new") ? url : `${url}&new`);
await waitFor(() => document.querySelector("textarea, [contenteditable=true]"));
const composerPaint = await t();
await waitFor(() => window.cmuxAcpmuxDebug?.models?.().current);
log("open: composer painted", composerPaint);
log("open: session usable (model chip)", await t());

// 2. Reopen a stored session that has turns (its agent is not running).
const sessions = (await state()).sessions;
const stored = sessions.find((s) => s.sessionId !== undefined && s.harness === "claude-sr" && s.title) ?? sessions[1];
const before = await t();
await page.evaluate((id) => window.cmuxAcpmuxDebug.selectSession(id), stored.sessionId);
await waitFor((id) => {
  const s = window.cmuxAcpmuxDebug.chatState();
  return s.sessionId === id && s.rows > 0;
}, stored.sessionId);
log("select stored session: rows shown", (await t()) - before);
log("select: session", { harness: stored.harness, rows: (await state()).rows, sessions: sessions.length });

// 3. Its first prompt: the daemon respawns the agent and loads the session first.
let start = await t();
void page.evaluate(() => window.cmuxAcpmuxDebug.sendPrompt("Reply with exactly: again"));
await waitFor(() => window.cmuxAcpmuxDebug.chatState().lastAssistant?.text?.includes("again"), null, 180_000).catch(
  () => undefined,
);
log("stored session: Enter -> reply text", (await t()) - start);
await waitFor(() => !window.cmuxAcpmuxDebug.chatState().isWorking, null, 180_000).catch(() => undefined);

// 4. Model switch on the live session.
const models = await page.evaluate(() => window.cmuxAcpmuxDebug.models());
const other = models.models.find((m) => m.id !== models.current && !/unavailable/.test(m.name));
if (other) {
  start = await t();
  const result = await page.evaluate((id) => window.cmuxAcpmuxDebug.setModel(id), other.id);
  await waitFor((id) => window.cmuxAcpmuxDebug.models().current === id, other.id, 30_000).catch(() => undefined);
  log("model switch -> chip shows it", (await t()) - start);
  log("model switch: result", { from: models.current, to: other.id, result });
}

// 5. Interrupt a running turn once text streams.
await page.evaluate(() => window.cmuxAcpmuxDebug.sendPrompt("Count from 1 to 400, one number per line, nothing else."));
await waitFor(() => (window.cmuxAcpmuxDebug.chatState().lastAssistant?.text ?? "").includes("5"), null, 120_000).catch(
  () => undefined,
);
start = await t();
await page.evaluate(() => window.cmuxAcpmuxActions["chat.cancel"]());
await waitFor(() => !window.cmuxAcpmuxDebug.chatState().isWorking, null, 60_000).catch(() => undefined);
log("interrupt -> turn stopped", (await t()) - start);

// 6. A harness the catalog lists that cannot start.
start = await t();
const failed = await page.evaluate(() =>
  window.cmuxAcpmuxDebug.newChat("gemini").then(
    (r) => r,
    (e) => ({ error: String(e) }),
  ),
);
log("unavailable harness: error after", (await t()) - start);
log("unavailable harness: result", failed);

// 7. Daemon restart: the pane reconnects and the session takes a prompt again.
if (restartCmd) {
  const sessionId = (await state()).sessionId;
  start = await t();
  execSync(restartCmd, { stdio: "inherit" });
  const restarted = await t();
  await waitFor(
    () => /disconnect|connecting|lost/i.test(String(window.cmuxAcpmuxDebug.chatState().connection)),
    null,
    10_000,
  ).catch(() => undefined);
  const lostAt = await t();
  await waitFor(
    (id) => {
      const s = window.cmuxAcpmuxDebug.chatState();
      return s.sessionId === id && /connected|ready|idle/i.test(String(s.connection)) && s.rows > 0;
    },
    sessionId,
    60_000,
  ).catch(() => undefined);
  log("restart: command took", restarted - start);
  log("restart: pane saw the loss after", lostAt - start);
  log("restart: pane reconnected after", (await t()) - start);
  log("restart: connection", (await state()).connection);
  start = await t();
  void page.evaluate(() => window.cmuxAcpmuxDebug.sendPrompt("Reply with exactly: back"));
  await waitFor(() => window.cmuxAcpmuxDebug.chatState().lastAssistant?.text?.includes("back"), null, 180_000).catch(
    () => undefined,
  );
  log("restart: first prompt -> reply text", (await t()) - start);
}
if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
await browser.close();
