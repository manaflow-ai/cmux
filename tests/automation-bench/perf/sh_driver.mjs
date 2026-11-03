// Stagehand v4 driver for bench.py: JSON lines on stdin/stdout, no model, no API key.
//   node sh_driver.mjs /tmp/cu-bench/stagehand/node_modules/@browserbasehq/stagehand/dist/index.mjs CHROME_PATH
// State is page.snapshot() (the hybrid accessibility tree observe() sends to the model); click and type use
// the xpath that tree maps to the element (what act() runs with an observe result, minus the model call).
import readline from "node:readline";

const [modPath, chrome] = process.argv.slice(2);
const SH = await import(modPath);
let browser, page, snap = { formattedTree: "", xpathMap: {} };

const LINE = /^\s*\[(?<id>[0-9-]+)\]\s+(?<role>[A-Za-z]+)(?::\s*(?<name>.*))?$/;
function xpathFor(target) {
  const hits = [];
  for (const line of snap.formattedTree.split("\n")) {
    const m = LINE.exec(line);
    const roles = Array.isArray(target.role) ? target.role : [target.role];
    if (!m || !roles.includes(m.groups.role)) continue;
    const name = (m.groups.name ?? "").trim();
    if (target.name != null) {
      if (target.exact ? name !== target.name : !name.toLowerCase().includes(target.name.toLowerCase())) continue;
    }
    hits.push(snap.xpathMap[m.groups.id]);
  }
  const x = hits[target.nth ?? 0];
  if (!x) throw new Error(`no ${target.role} ${target.name ?? ""} in the tree`);
  return x;
}

const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
out({ ready: true });
const rl = readline.createInterface({ input: process.stdin });
for await (const line of rl) {
  const msg = JSON.parse(line);
  const t0 = performance.now();
  try {
    let text = "";
    if (msg.op === "start") {
      browser = await SH.localBrowser.launch({ headless: true, executablePath: chrome });
      await SH.Stagehand.create({ browser });
      page = (await browser.context.pages())[0] ?? (await browser.context.newPage());
    } else if (msg.op === "goto") {
      await page.goto(msg.arg, { waitUntil: "load" });
    } else if (msg.op === "state") {
      snap = await page.snapshot();
      text = snap.formattedTree;
    } else if (msg.op === "click") {
      await page.locator(`xpath=${xpathFor(msg.target)}`).click();
    } else if (msg.op === "type") {
      const loc = page.locator(`xpath=${xpathFor(msg.target)}`);
      await loc.fill(msg.target.text);
      if (msg.target.submit) await page.keyPress("Enter");
    } else if (msg.op === "stop") {
      try { await browser?.close?.(); } catch {}
      out({ ok: true });
      process.exit(0);
    }
    out({ ok: true, text, inner_ms: performance.now() - t0 });
  } catch (e) {
    out({ ok: false, error: String(e?.stack ?? e).slice(0, 400) });
  }
}
