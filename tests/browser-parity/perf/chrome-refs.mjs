// The Chrome references for bench.mjs, timed in this process on headless
// Google Chrome with a throwaway profile:
//   pw-mcp      Playwright's `_snapshotForAI()`, the snapshot Playwright MCP
//               returns (full, then incremental after the change).
//   chatgpt-ax  ChatGPT for Chrome's AX text, rendered offline by the
//               reference in git history (compare/adapters.mjs), full with
//               { disableDiffing: true }, then its default diffing state.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadPlaywright } from "../lib/dev-driver.mjs";
import { DESKTOP_UA, VIEWPORT } from "../compare/adapters.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../../..");
const CHATGPT_REF_COMMIT = "2e4c54b6fa8";

function chatgptReferencePath() {
  const dest = path.join(here, "../compare/results/.cache/chatgpt-ax-reference.mjs");
  if (!fs.existsSync(dest)) {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, execFileSync("git", ["-C", repoRoot, "show", `${CHATGPT_REF_COMMIT}:tests/browser-parity/lib/chatgpt-ax-reference.mjs`], { maxBuffer: 1 << 24 }));
  }
  return dest;
}

export async function createChromeReferences({ runs, mutate }) {
  const { loadChatGPTAccessibilityCore, ChatGPTAxReference } = await import(chatgptReferencePath());
  const core = await loadChatGPTAccessibilityCore();
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const timed = async (fn) => {
    const t = Date.now();
    const v = await fn();
    return [v, Date.now() - t];
  };
  return {
    async page(p) {
      const context = await browser.newContext({ viewport: VIEWPORT, userAgent: DESKTOP_UA });
      const page = await context.newPage();
      page.on("dialog", (d) => d.dismiss().catch(() => {}));
      const pw = { name: p.name, runs: [] };
      const ax = { name: p.name, runs: [] };
      try {
        await page.goto(p.url, { waitUntil: "load", timeout: 90_000 }).catch((e) => {
          if (!/timeout/i.test(e.message)) throw e;
        });
        await page.waitForTimeout(p.settle);
        const axRef = new ChatGPTAxReference(page, core, { tabId: 1 });
        for (let i = 0; i < runs; i++) {
          const [snap, ms] = await timed(() => page._snapshotForAI({ track: "perf" }));
          pw.runs.push({ snapMs: ms, treeChars: snap.full.length });
          if (i === 0) pw.tree = snap.full;
          try {
            const [text, axMs] = await timed(() => axRef.state({ disableDiffing: true }));
            ax.runs.push({ snapMs: axMs, treeChars: text.length });
            if (i === 0) ax.tree = text;
          } catch (e) {
            ax.error = String(e.message || e);
          }
        }
        // ChatGPT diffs against its last diffing state; take one first.
        await axRef.state().catch(() => {});
        await page.evaluate(mutate);
        {
          const [snap, ms] = await timed(() => page._snapshotForAI({ track: "perf" }));
          pw.diff = { snapMs: ms, diffChars: (snap.incremental || "").length, printed: String(snap.incremental || "").slice(0, 4000) };
        }
        if (!ax.error) {
          const [text, ms] = await timed(() => axRef.state());
          ax.diff = { snapMs: ms, diffChars: text.length, printed: text.slice(0, 4000) };
        }
        const refs = [...pw.tree.matchAll(/\[ref=(\w+)\]/g)].map((m) => m[1]).filter((r) => !r.startsWith("f"));
        pw.refCount = refs.length;
        const last = refs.pop();
        if (last) {
          const [, ms] = await timed(() => page.locator(`aria-ref=${last}`).textContent({ timeout: 10_000 }).catch(() => null));
          pw.locatorMs = ms;
        }
      } catch (e) {
        pw.error = pw.error || String(e.message || e);
      } finally {
        await context.close().catch(() => {});
      }
      return { name: p.name, tools: { "pw-mcp": pw, "chatgpt-ax": ax } };
    },
    async overhead() {
      return null;
    },
    async leak() {
      return null;
    },
    close: () => browser.close(),
  };
}
