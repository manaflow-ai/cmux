// Scratch profiler (not committed): self time per function for keys typed at the end of a long draft.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { waitForServerReady } from "./scripts/latency/run";

const webviews = import.meta.dir;
const outDir = "/tmp/cmux-latency-profile";
fs.writeFileSync(
  path.join(webviews, "vite.config.latency-profile.ts"),
  `import base from "./vite.config.latency";\nexport default { ...base, build: { ...base.build, minify: false } };\n`,
);
const vp = path.join(webviews, "node_modules/.bin/vp");
const env = { ...process.env, CMUX_LATENCY_OUT_DIR: outDir };
const built = spawnSync(vp, ["build", "--config", "vite.config.latency-profile.ts"], { cwd: webviews, env, encoding: "utf8" });
if (built.status !== 0) throw new Error(String(built.stderr).slice(-3000));
const port = 4719;
const server = spawn(vp, ["preview", "--config", "vite.config.latency-profile.ts", "--port", String(port), "--strictPort"], {
  cwd: webviews,
  env,
  stdio: ["ignore", "pipe", "pipe"],
});
await waitForServerReady(server, port);
const editor = ".acpmux-composer [contenteditable='true']";
const LINE = "composer latency fixture words keep the prompt long ".repeat(2).trim();
const browser = await chromium.launch();
try {
  for (const [label, query, chars] of [
    ["draft 200k", "", 200_000],
  ] as const) {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/latency/flows.html?mock${query}`);
    await page.waitForFunction(() => document.documentElement.dataset.latencyFlowsReady === "true", undefined, {
      timeout: 60_000,
    });
    await page.evaluate("window.__latencyFlows.restoreChat()");
    await page.waitForSelector(editor);
    await page.focus(editor);
    await page.evaluate(
      async ({ chars, line, editor }) => {
        const field = document.querySelector<HTMLElement>(editor)!;
        const words = line.split(" ").length;
        const perPaste = Math.max(1, Math.floor(Math.min(8_000 / (line.length + 1), 600 / words)));
        let laid = 0;
        while (laid < chars) {
          const lines: string[] = [];
          for (let at = 0; at < perPaste && laid < chars; at += 1) {
            lines.push(line);
            laid += line.length + 1;
          }
          const transfer = new DataTransfer();
          transfer.setData("text/plain", `\n${lines.join("\n")}.`);
          field.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
          await new Promise((resolve) => setTimeout(resolve, 0));
        }
      },
      { chars, line: LINE, editor },
    );
    await page.waitForTimeout(1500);
    console.log(label, "doc shape", await page.evaluate((e) => { const el = document.querySelector(e)!; return { children: el.children.length, first: el.firstElementChild?.textContent?.length, last: el.lastElementChild?.textContent?.length, tags: [...new Set([...el.children].map((c) => c.tagName))] }; }, editor));
    console.log(label, "draft chars", await page.evaluate((e) => document.querySelector(e)?.textContent?.length, editor));
    await page.keyboard.press("ControlOrMeta+End");
    await page.waitForTimeout(500);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
    await page.evaluate(() => {
      (window as any).__keys = [];
      document.addEventListener(
        "keydown",
        (event) => {
          const at = event.timeStamp;
          requestAnimationFrame(() => setTimeout(() => (window as any).__keys.push(performance.now() - at), 0));
        },
        { capture: true },
      );
    });
    await cdp.send("Profiler.start");
    for (let i = 0; i < 20; i += 1) {
      await page.keyboard.press("x");
      await page.waitForTimeout(120);
    }
    const { profile } = await cdp.send("Profiler.stop");
    const keys = (await page.evaluate("window.__keys")) as number[];
    keys.sort((a, b) => a - b);
    console.log(label, "key->post-paint ms p50", keys[keys.length >> 1]?.toFixed(1), "max", keys.at(-1)?.toFixed(1));
    const self = new Map<number, number>();
    const dt = profile.timeDeltas ?? [];
    profile.samples?.forEach((id, i) => self.set(id, (self.get(id) ?? 0) + (dt[i] ?? 0)));
    const byName = new Map<string, number>();
    const parent = new Map<number, number>();
    for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
    const nodes = new Map(profile.nodes.map((node) => [node.id, node]));
    const total = new Map<string, number>();
    for (const node of profile.nodes) {
      const f = node.callFrame;
      const key = `${f.functionName || "(anon)"} ${path.basename(f.url)}:${f.lineNumber}`;
      byName.set(key, (byName.get(key) ?? 0) + (self.get(node.id) ?? 0));
      // inclusive: add this node's self time to every distinct ancestor key
      const seen = new Set<string>();
      let at: number | undefined = node.id;
      while (at !== undefined) {
        const cf = nodes.get(at)!.callFrame;
        const k = `${cf.functionName || "(anon)"} ${path.basename(cf.url)}:${cf.lineNumber}`;
        if (!seen.has(k)) {
          seen.add(k);
          total.set(k, (total.get(k) ?? 0) + (self.get(node.id) ?? 0));
        }
        at = parent.get(at);
      }
    }
    const top = (map: Map<string, number>, n: number) =>
      [...map.entries()]
        .filter(([k]) => !/^\((idle|program|root|garbage collector)\)/.test(k))
        .sort((a, b) => b[1] - a[1])
        .slice(0, n)
        .map(([k, v]) => `  ${(v / 1000 / 20).toFixed(2).padStart(8)} ms/key  ${k}`)
        .join("\n");
    console.log(`${label} SELF\n${top(byName, 30)}`);
    console.log(`${label} INCLUSIVE\n${top(total, 60)}`);
    await page.close();
  }
} finally {
  await browser.close();
  server.kill("SIGKILL");
  process.exit(0);
}
