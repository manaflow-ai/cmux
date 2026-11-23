import path from "node:path";
import { createServer } from "vite";
import { chromium } from "playwright";
const webviews = process.cwd();
const server = await createServer({ configFile: path.join(webviews, "vite.config.ts"), root: webviews, server: { port: 0, strictPort: false, host: "127.0.0.1" }, logLevel: "warn" });
await server.listen();
const { port } = server.httpServer.address();
const b = await chromium.launch({ executablePath: "/usr/bin/google-chrome", args: ["--no-sandbox"] });
const p = await b.newPage({ viewport: { width: 980, height: 820 } });
p.on("pageerror", (e) => console.log("PAGEERR", e.message.slice(0, 300)));
p.on("response", (r) => { if (r.status() >= 400) console.log("HTTP", r.status(), r.url()); });
p.on("console", (m) => { if (m.type() === "error") console.log("CERR", m.text().slice(0, 300)); });
const t = Date.now();
await p.goto(`http://127.0.0.1:${port}/agent-pane/?mock`);
console.log("loaded", Date.now() - t);
for (let i = 0; i < 18; i++) {
  const ok = await p.locator(".ProseMirror").count();
  if (ok) { console.log("editor at", Date.now() - t); break; }
  await p.waitForTimeout(5000);
}
console.log("BODY", JSON.stringify(await p.evaluate(() => document.body.innerText.slice(0, 400))));
console.log("ROOT", (await p.evaluate(() => document.body.innerHTML.slice(0, 400))));
await p.screenshot({ path: "/tmp/hsp/s2.png" });
await b.close(); await server.close();
