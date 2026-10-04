// Sends a prompt 300 ms after a harness pick in the production pane and reports which harness's
// session received it (the pick has not finished session/new yet).
//   bun scripts/agent-pane/bench-switch-race.mjs --url "<agent pane URL>" [--to codex] [--delay 300]
import { chromium } from "playwright";
const arg = (n, f) => (process.argv.indexOf(`--${n}`) >= 0 ? process.argv[process.argv.indexOf(`--${n}`) + 1] : f);
const url = arg("url");
const to = arg("to", "codex");
const delay = Number(arg("delay", 300));
const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(url.includes("&new") ? url : `${url}&new`);
await page.waitForFunction(() => window.cmuxAcpmuxDebug?.models?.().current, null, { timeout: 90_000 });
const result = await page.evaluate(
  async ({ to, delay }) => {
    const d = window.cmuxAcpmuxDebug;
    const from = d.chatState();
    const switching = d.newChat(to);
    await new Promise((r) => setTimeout(r, delay));
    const atSend = d.chatState();
    const sent = await d.sendPrompt("Reply with exactly: which");
    await switching;
    const after = d.chatState();
    const target = after.sessions.find((s) => s.sessionId === sent.sessionId);
    return {
      picked: to,
      from: from.harness,
      shownWhenSent: atSend.harness,
      promptLandedIn: target?.harness ?? sent.sessionId,
      nowShowing: after.harness,
    };
  },
  { to, delay },
);
console.log(JSON.stringify(result));
await browser.close();
