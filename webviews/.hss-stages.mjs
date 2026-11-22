// Headless stage timing of a .tsx save on the webviews dev server: save -> watcher event ->
// HMR ws message -> module fetch (transform). Run from webviews/: node stages.mjs RUNS
import path from "node:path";
import fs from "node:fs";
import { createServer } from "vite";
const webviews = process.cwd();
const RUNS = Number(process.argv[2] || 12);
const PORT = Number(process.env.PORT || 4417);
const EDITS = {
  settings: ["src/pages/settings/components/SettingsApp.tsx", '{t("settingsPage.title")}</h2>', '{t("settingsPage.title")} hot</h2>'],
  composer: ["src/agent-session/acpmux/ComposerFoot.tsx", "{children}</InQuietRow.Provider>", "{children}<span>hot</span></InQuietRow.Provider>"],
};
const now = () => performance.now();
const marks = {};
const server = await createServer({ configFile: path.join(webviews, "vite.config.ts"), root: webviews,
  server: { port: PORT, strictPort: true, host: "127.0.0.1" }, logLevel: "warn",
  plugins: [{ name: "stage-probe", enforce: "pre", hotUpdate() { marks.hot ??= now(); },
    transform(code, id) { if (marks.save && /SettingsApp|ComposerFoot/.test(id)) { marks.transformStart ??= now(); } } },
    { name: "stage-probe-post", enforce: "post", transform(code, id) { if (marks.save && /SettingsApp|ComposerFoot/.test(id)) marks.transformEnd = now(); } }] });
await server.listen();
server.watcher.on("change", (f) => { if (/SettingsApp|ComposerFoot/.test(f)) marks.watch ??= now(); });
const client = await (await fetch(`http://127.0.0.1:${PORT}/@vite/client`)).text();
const token = client.match(/const wsToken = "([^"]*)"/)?.[1] ?? "";
const ws = new WebSocket(`ws://127.0.0.1:${PORT}/?token=${token}`, "vite-hmr");
await new Promise((r) => ws.addEventListener("open", r));
let waiter;
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.type === "connected" || m.type === "ping") return; marks.ws ??= now(); marks.msg ??= m; waiter?.(); });
const rows = [];
for (const name of Object.keys(EDITS)) {
  const [rel, a, b] = EDITS[name];
  const file = path.join(webviews, rel);
  // Load once so it is in the module graph (self-accepting under React Refresh).
  await (await fetch(`http://127.0.0.1:${PORT}/${rel}`)).text();
  const original = fs.readFileSync(file, "utf8");
  try {
    for (let i = 0; i < RUNS; i++) {
      await new Promise((r) => setTimeout(r, 400));
      for (const k of Object.keys(marks)) delete marks[k];
      const src = fs.readFileSync(file, "utf8");
      const next = src.includes(b) ? src.replace(b, a) : src.replace(a, b);
      const got = new Promise((r) => { waiter = r; setTimeout(r, 5000); });
      marks.save = now();
      fs.writeFileSync(file, next);
      await got; waiter = undefined;
      const m = marks.msg;
      let fetchMs = null, type = m?.type, paths = [];
      if (m?.type === "update") {
        const f0 = now();
        await Promise.all(m.updates.map(async (u) => { paths.push(u.acceptedPath); const r = await fetch(`http://127.0.0.1:${PORT}${u.acceptedPath}${u.acceptedPath.includes("?") ? "&" : "?"}t=${u.timestamp}`); await r.text(); }));
        fetchMs = now() - f0;
      }
      const s = marks.save; const d = (k) => (marks[k] != null ? +(marks[k] - s).toFixed(1) : null);
      rows.push({ name, i, type, paths, watch: d("watch"), hot: d("hot"), ws: d("ws"), fetch: fetchMs && +fetchMs.toFixed(1), transform: marks.transformEnd && marks.transformStart ? +(marks.transformEnd - marks.transformStart).toFixed(1) : null, total: marks.ws ? +((marks.ws - s) + (fetchMs ?? 0)).toFixed(1) : null });
      console.log(JSON.stringify(rows.at(-1)));
    }
  } finally { fs.writeFileSync(file, original); }
}
const pct = (v, q) => { v = v.filter((x) => x != null).sort((x, y) => x - y); return v.length ? v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)] : null; };
for (const name of Object.keys(EDITS)) { const r = rows.filter((x) => x.name === name);
  const out = { name, n: r.length }; for (const k of ["watch", "hot", "ws", "fetch", "transform", "total"]) out[k] = { p50: pct(r.map((x) => x[k]), 0.5), p95: pct(r.map((x) => x[k]), 0.95) };
  console.log("SUMMARY " + JSON.stringify(out)); }
ws.close(); await server.close(); process.exit(0);
