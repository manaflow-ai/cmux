// Live ChatGPT for Chrome captures for the representation comparison.
//
// Drives the installed ChatGPT browser runtime through the user's reference
// client (cmux-browser-cli/scripts/cua-reference-client.ts) in the user's
// Chrome, inside one named session group. Every page is served from one
// approved disposable origin (127.0.0.1:PRIMARY); cross-origin frames point
// at a second, unapproved loopback origin, and whatever ChatGPT does with them
// is recorded, never approved. No live sites, raw CDP, downloads, history or
// uploads. Every tab the session opens is closed in `finally`.
//
//   CUA_REFERENCE_CODEX=$HOME/.codex/plugins/.plugin-appserver/codex \
//   /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node \
//     --experimental-strip-types tests/browser-parity/compare/chatgpt-live.ts [--only NAME]
//
// Two passes: AX mode (the production default: tab.ax, tab.playwright) and
// legacy mode (BROWSER_USE_TINYSKY_ENABLED=0), the only mode with tab.dom_cua.
// Writes results/chatgpt-live/<page>/{chatgpt-live-ax,-dom,-pw}.txt and
// results/chatgpt-live/scenarios.json.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const clientPath = path.join(process.env.CMUX_BROWSER_CLI ?? path.join(os.homedir(), "fun/cmux-browser-cli"), "scripts/cua-reference-client.ts");
const { CuaReferenceClient } = await import(clientPath);
const fixtures = path.resolve(here, "../fixtures");
const pagesDir = path.join(here, "pages");
const outDir = path.join(here, "results/chatgpt-live");
const PRIMARY = 18911;
const PEER = 18912;
export const CORPUS_CSP = "default-src 'self' 'unsafe-inline' data:; img-src 'self' data:";

const only = process.argv.includes("--only") ? process.argv[process.argv.indexOf("--only") + 1] : null;
// Only the action-flow and ref scenarios (AX mode), keeping page captures.
const scenariosOnly = process.argv.includes("--scenarios-only");
// Run one pass only: --mode ax | legacy.
const modeOnly = process.argv.includes("--mode") ? process.argv[process.argv.indexOf("--mode") + 1] : null;

// Same routes as run.mjs serves: fixtures at /, the corpus at /corpus/, the
// nested-frame and big pages at /pages/ (absolute URLs rewritten).
function serve(port: number) {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url ?? "/", "http://x");
    let file: string;
    let rewrite = false;
    let csp: string | null = null;
    if (u.pathname.startsWith("/pages/")) {
      file = path.join(pagesDir, path.basename(u.pathname));
      rewrite = true;
    } else if (u.pathname.startsWith("/corpus/")) {
      file = path.join(fixtures, "corpus", path.basename(u.pathname));
      csp = CORPUS_CSP;
    } else file = path.join(fixtures, u.pathname === "/" ? "index.html" : path.basename(u.pathname));
    if (u.pathname === "/favicon.ico" || !fs.existsSync(file)) return void res.writeHead(404).end();
    let body: string | Buffer = fs.readFileSync(file);
    if (rewrite) body = body.toString("utf8").replaceAll("localhost:8811/", `127.0.0.1:${PRIMARY}/pages/`).replaceAll("127.0.0.1:8812/", `127.0.0.1:${PEER}/pages/`);
    const headers: Record<string, string> = { "content-type": file.endsWith(".js") ? "text/javascript" : "text/html; charset=utf-8", "cache-control": "no-store" };
    if (csp) headers["content-security-policy"] = csp;
    res.writeHead(200, headers).end(body);
  });
  return new Promise<http.Server>((r) => server.listen(port, "127.0.0.1", () => r(server)));
}

const FIXTURES = ["index", "aria", "states", "frames", "frame-inner", "shadow", "surface", "dynamic", "input", "dialogs", "files"];
const CORPUS = fs.readdirSync(path.join(fixtures, "corpus")).filter((f) => f.endsWith(".html")).map((f) => f.replace(/\.html$/, ""));
const origin = `http://127.0.0.1:${PRIMARY}`;
const peer = `http://127.0.0.1:${PEER}`;
const pages = [
  ...FIXTURES.map((f) => ({ name: f, url: `${origin}/${f === "index" ? "" : f + ".html"}?peer=${encodeURIComponent(peer)}` })),
  { name: "nest", url: `${origin}/pages/top.html` },
  ...CORPUS.map((c) => ({ name: `corpus-${c}`, url: `${origin}/corpus/${c}.html` })),
].filter((p) => !only || p.name === only);


const write = (page: string, tool: string, text: string) => {
  fs.mkdirSync(path.join(outDir, page), { recursive: true });
  fs.writeFileSync(path.join(outDir, page, `${tool}.txt`), text);
};
const errText = (e: unknown) => String((e as Error)?.message ?? e).split("\n").slice(0, 3).join(" ").slice(0, 400);
const indexOf = (state: string, re: RegExp) => {
  const m = state.match(re);
  return m ? Number(m[1]) : null;
};

async function pass(mode: "ax" | "legacy", scenarios: Record<string, unknown>) {
  process.env.CUA_REFERENCE_AX_MODE = mode === "ax" ? "1" : "0";
  process.env.CUA_REFERENCE_CODEX ??= path.join(os.homedir(), ".codex/plugins/.plugin-appserver/codex");
  const uploadDir = fs.mkdtempSync(path.join(os.tmpdir(), "cmp-cg-"));
  const upload = path.join(uploadDir, "parity-upload.txt");
  fs.writeFileSync(upload, "Disposable browser parity upload\n");
  const c = new CuaReferenceClient();
  fs.mkdirSync(path.join(here, "results/.cache"), { recursive: true });
  fs.writeFileSync(path.join(here, "results/.cache/chatgpt-live-session.txt"), c.sessionId + "\n");
  const stop = async () => {
    await closeAll(c);
    await c.close();
    process.exit(130);
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    await c.initialize();
    c.authorizeLocalFixture(origin, upload);
    await c.js('var rb=await cua.getBrowser({id:"chrome"});');
    await c.js('await rb.nameSession("🧪 cmux parity");');
    await c.js("var rt=await rb.tabs.new();");
    for (const p of scenariosOnly ? [] : pages) {
      const t0 = Date.now();
      try {
        await c.js(`await rt.goto(${JSON.stringify(p.url)}); await new Promise(r=>setTimeout(r,${p.name.startsWith("corpus") ? 1200 : 600}));`);
      } catch (e) {
        console.log(`  ${p.name} goto failed: ${errText(e)}`);
        continue;
      }
      const grab = async (tool: string, expr: string) => {
        try {
          const v = await c.value(expr);
          write(p.name, tool, typeof v === "string" ? v : JSON.stringify(v, null, 1));
        } catch (e) {
          write(p.name, tool, `ERROR: ${errText(e)}`);
        }
      };
      if (mode === "ax") {
        await grab("chatgpt-live-ax", 'rt.ax.get("state",{disableDiffing:true})');
        await grab("chatgpt-live-pw", "rt.playwright.domSnapshot()");
      } else await grab("chatgpt-live-dom", "rt.dom_cua.get_visible_dom()");
      console.log(`  ${mode} ${p.name} ${Date.now() - t0}ms`);
    }
    if (mode === "ax" && !only) {
      // Action flow on the form fixture, by AX index as the model acts.
      const flow: Record<string, unknown> = {};
      await c.js(`await rt.goto(${JSON.stringify(pages[0].url)}); await new Promise(r=>setTimeout(r,600));`);
      const s0: string = await c.value('rt.ax.get("state",{disableDiffing:true})');
      const email = indexOf(s0, /^\s*(\d+) text field[^\n]*Email/m);
      const tos = indexOf(s0, /^\s*(\d+) checkbox[^\n]*Accept terms/m);
      const submit = indexOf(s0, /^\s*(\d+) button Create account/m);
      flow.indices = { email, tos, submit };
      flow.before = s0;
      await c.value("rt.ax.get()"); // prime the diff baseline after the full capture
      for (const [label, code] of [["setValue", `rt.ax.setValue(${email},"me@x.com")`], ["click checkbox", `rt.ax.click(${tos})`], ["click submit", `rt.ax.click(${submit})`]]) {
        try {
          await c.js(`await ${code};`);
        } catch (e) {
          flow[`${label} error`] = errText(e);
        }
      }
      await c.js("await new Promise(r=>setTimeout(r,300));");
      flow.after = await c.value("rt.ax.get()");
      flow.afterFull = await c.value('rt.ax.get("state",{disableDiffing:true})');
      flow.page = await c.value('rt.playwright.evaluate("(document.getElementById(\'ok\')||{}).textContent||null")').catch((e: unknown) => `ERROR: ${errText(e)}`);
      scenarios.actionFlow = flow;

      // Ref stability by AX index. Page evaluation is read-only in this
      // runtime, so pages/refs.html applies the mutation on a click.
      const refs: Record<string, unknown> = {};
      await c.js(`await rt.goto(${JSON.stringify(origin + "/pages/refs.html")}); await new Promise(r=>setTimeout(r,600));`);
      const r1: string = await c.value('rt.ax.get("state",{disableDiffing:true})');
      const mutate = indexOf(r1, /^\s*(\d+) button Mutate/m);
      await c.js(`await rt.ax.click(${mutate});`);
      await c.js("await new Promise(r=>setTimeout(r,300));");
      const r2: string = await c.value('rt.ax.get("state",{disableDiffing:true})');
      refs.before = r1;
      refs.after = r2;
      const alpha = indexOf(r1, /^\s*(\d+) button Alpha/m);
      const out = indexOf(r1, /^\s*(\d+) button Out/m);
      try {
        await c.js(`await rt.ax.click(${alpha});`);
        refs.oldAlpha = "clicked";
      } catch (e) {
        refs.oldAlpha = errText(e);
      }
      try {
        await c.js(`await rt.ax.click(${out});`);
        refs.oldOut = await c.value('rt.playwright.evaluate("document.getElementById(\'out\').textContent")');
      } catch (e) {
        refs.oldOut = errText(e);
      }
      scenarios.refs = refs;
    }
    scenarios[`approvals-${mode}`] = c.approvalRequests.map((a: any) => ({ decision: a.decision, tool: a.params?._meta?.tool_name ?? null, origin: a.params?._meta?.origin ?? a.params?._meta?.tool_params?.origin ?? null }));
  } finally {
    await closeAll(c);
    await c.close();
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
    fs.rmSync(uploadDir, { recursive: true, force: true });
  }
}

// Closes every tab this session owns; Chrome rejects claims on other tabs.
async function closeAll(c: any) {
  try {
    await c.js('var cb=await cua.getBrowser({id:"chrome"}); for (const t of await cb.tabs.list()) await (await cb.tabs.get(t.id)).close();');
  } catch (e) {
    console.log(`cleanup failed: ${errText(e)}`);
  }
}

const servers = await Promise.all([serve(PRIMARY), serve(PEER)]);
const scenarios: Record<string, unknown> = {};
try {
  if (modeOnly !== "legacy") await pass("ax", scenarios);
  if (!scenariosOnly && modeOnly !== "ax") await pass("legacy", scenarios);
} finally {
  for (const s of servers) s.close();
}
if (!only) {
  // A partial run keeps what it did not redo.
  const f = path.join(outDir, "scenarios.json");
  if (fs.existsSync(f)) {
    const old = JSON.parse(fs.readFileSync(f, "utf8"));
    for (const k of Object.keys(old)) if (!(k in scenarios)) scenarios[k] = old[k];
  }
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "scenarios.json"), JSON.stringify({ capturedAt: new Date().toISOString(), origin, peer, ...scenarios }, null, 1));
}
console.log("done");
process.exit(0);
