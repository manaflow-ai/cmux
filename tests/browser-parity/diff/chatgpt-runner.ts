// ChatGPT for Chrome side of the differential harness. Started by run.mjs
// under ChatGPT's bundled node; drives the installed reference runtime through
// the user's reference client (cmux-browser-cli/scripts/cua-reference-client.ts)
// exactly as compare/chatgpt-live.ts does:
//
// - approval covers one temporary origin (ORIGINS.primary, 127.0.0.1) and the
//   disposable parity-upload.txt; every other origin a case touches is denied
//   by the client and the denial is recorded as the outcome;
// - every tab lives in the "🧪 cmux parity" session group and is closed after
//   each case and in `finally`;
// - no raw CDP, no history, no live sites.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const { loadCases, dialectSource, expand, prelude } = await import(path.join(here, "lib.mjs"));
const clientPath = path.join(process.env.CMUX_BROWSER_CLI ?? path.join(os.homedir(), "fun/cmux-browser-cli"), "scripts/cua-reference-client.ts");
const { CuaReferenceClient } = await import(clientPath);

const [input, output] = process.argv.slice(2);
const { ids, origins } = JSON.parse(fs.readFileSync(input, "utf8"));
const wanted = new Set(ids);
const cases = (await loadCases()).filter((c: any) => wanted.has(c.id));

const errText = (e: unknown) => String((e as Error)?.message ?? e).split("\n").slice(0, 4).join(" ").slice(0, 800);
const uploadDir = fs.mkdtempSync(path.join(os.tmpdir(), "brepl-diff-cg-"));
const upload = path.join(uploadDir, "parity-upload.txt");
fs.writeFileSync(upload, "Disposable browser parity upload\n");

const c = new CuaReferenceClient();
fs.mkdirSync(path.join(here, "results/.cache"), { recursive: true });
fs.writeFileSync(path.join(here, "results/.cache/chatgpt-session.txt"), c.sessionId + "\n");

async function closeAll() {
  try {
    await c.js('var cb=await cua.getBrowser({id:"chrome"}); for (const x of await cb.tabs.list()) { try { const tt=await cb.tabs.get(x.id); const d=await tt.getJsDialog().catch(()=>null); if (d) await d.dismiss().catch(()=>{}); await tt.close(); } catch {} }');
  } catch (e) {
    console.log(`  chatgpt cleanup failed: ${errText(e)}`);
  }
}

const out: Record<string, unknown> = {};
const stop = async () => {
  await closeAll();
  await c.close();
  process.exit(130);
};
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
try {
  await c.initialize();
  c.authorizeLocalFixture(origins.primary, upload);
  await c.js('var rb=await cua.getBrowser({id:"chrome"}); await rb.nameSession("🧪 cmux parity");');
  await c.js(`var PARITY_UPLOAD=${JSON.stringify(upload)};`);
  for (const k of cases) {
    const t0 = Date.now();
    let r: any;
    try {
      if (k.custom?.chatgpt) {
        r = { value: await k.custom.chatgpt({ c, origins, upload, prelude: prelude(origins) }) };
      } else {
        const body = expand(dialectSource(k, "chatgpt"), "chatgpt");
        await c.js(`var __t=await rb.tabs.new();${k.path == null ? "" : `await __t.goto(${JSON.stringify(origins.primary + k.path)});`}`);
        const v = await c.value(`(async () => { ${prelude(origins)}\nconst t = __t, b = rb;\n${body}\n})()`);
        r = { value: v === undefined ? null : v };
      }
    } catch (e) {
      r = { uncaught: errText(e) };
    }
    await closeAll();
    out[k.id] = { ...r, ms: Date.now() - t0 };
    console.log(`  chatgpt ${k.id} ${out[k.id] && (out[k.id] as any).ms}ms ${r.uncaught ? "UNCAUGHT " + r.uncaught.slice(0, 160) : JSON.stringify(r.value).slice(0, 160)}`);
  }
  out.__approvals = c.approvalRequests.map((a: any) => ({ decision: a.decision, tool: a.params?._meta?.tool_name ?? null, origin: a.params?._meta?.origin ?? a.params?._meta?.tool_params?.origin ?? null }));
} catch (e) {
  console.log(`chatgpt runner failed: ${errText(e)}`);
} finally {
  await closeAll();
  await c.close();
  fs.rmSync(uploadDir, { recursive: true, force: true });
}
const approvals = out.__approvals;
delete out.__approvals;
fs.writeFileSync(output, JSON.stringify(out));
if (approvals) fs.writeFileSync(path.join(here, "results/.cache/chatgpt-approvals.json"), JSON.stringify(approvals, null, 1));
process.exit(0);
