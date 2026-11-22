// l10n-allow-file: benchmark output, not shipped UI.
// What the agent pane's code costs the Home Channels and Home Messages pages on their eager load
// (design/agent-pane-mount-sites.md row 10; Leo, 2026-11-22: "not just here, but anywhere you'd expect an agent pane
// to load, and anywhere you wouldn't expect but it still loads."). The pages import pane code (the composer's
// PromptEditor, AgentMessageRow, Markdown and the rest of src/agent-session/), and every static import is in the
// page's first load (bundle.mjs modulepreloads the whole static closure).
//
// 1. Build: `scripts/cmux-next/build-pages-web.sh --out DIR` (the tree the app ships) with CMUX_PAGES_METAFILE, then
//    the same esbuild JS pass again (bundle.mjs's options and plugins, every page the script builds) with source maps
//    into DIR-maps, whose JS replaces the shipped tree's in a copy (DIR-maps/<page>/index.html with that build's
//    modulepreload links), so a CPU profile names source files.
// 2. Bytes (from the shipped metafile): the page's eager JS (its app.js and every chunk it statically imports), and
//    the part of it that is pane code: the files reachable from the page's main.tsx by static imports minus those
//    still reachable once every import from outside src/agent-session/ into it is cut. The same for the page's CSS
//    (an isolated esbuild CSS pass per page, as bundle.mjs's, with a metafile). Then per import group (PromptEditor,
//    AgentMessageRow + AgentMessageBody + MessageCard, Markdown, and all three) the bytes that cutting only that group's imports
//    removes, and the 12 imported pane files that each remove the most.
// 3. Script ms: each round a fresh Chromium opens DIR/<page>/index.html?mock (the page on its in-page mock provider,
//    production React) at CPU (CDP throttling) and reads ScriptDuration when the first editable field is in the
//    document (ready, when there is one) and once nothing changed for 1000 ms (settled). Then, on the source-mapped
//    copy, a 100 us-sampled CPU profile from navigation to settled: self ms in pane code (the files of step 2) and in
//    all code, so the pane's share of the page's script time.
// Knobs: CPU (default 1), ROUNDS (default 5), PAGES (default home-channels,home-messages), KEEP=1 keeps the trees.
// One `HOME_PANE_IMPORTS_JSON {...}` line carries every number.
// Commands (from webviews/; on the fleet: cmux-ci test --setup playwright --timeout 2400 -- 'cd webviews && ...'):
//   quiet    ROUNDS=5 bun bench/home-pane-imports.bench.ts
//   loaded   ROUNDS=5 CPU=4 bun bench/home-pane-imports.bench.ts
/// <reference types="bun" />
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CDPSession } from "playwright";
import { build, type Metafile, type Plugin } from "esbuild";
import { chromium } from "./browsers";
import { sourceMapper } from "./sourceMapper";
import { requireProductionReact } from "./support/benchPage";
import { reactCompilerMode } from "../reactCompiler.mjs";
import { reactCompilerPlugin } from "../scripts/agent-pane/reactCompilerPlugin.mjs";
import { artifactRuntimePlugin } from "../scripts/agent-pane/artifactRuntimePlugin.mjs";
import { tailwindPlugin } from "../scripts/agent-pane/tailwindCompile.mjs";
import { createJsonParsePlugin } from "../scripts/agent-pane/jsonParsePlugin.mjs";
import { katexStylePlugin } from "../scripts/agent-pane/katexStylePlugin.mjs";

const CPU = Number(process.env.CPU ?? 1);
const ROUNDS = Number(process.env.ROUNDS ?? 5);
const PAGES = (process.env.PAGES ?? "home-channels,home-messages").split(",");
if (!Number.isFinite(CPU) || CPU < 1) throw new Error("CPU must be a number of at least 1");
if (!Number.isInteger(ROUNDS) || ROUNDS < 1) throw new Error("ROUNDS must be a whole number of at least 1");
const SETTLE_MS = 1000;
const PANE = "src/agent-session/";
const GROUPS: Record<string, string[]> = {
  PromptEditor: ["src/agent-session/acpmux/composer/PromptEditor.tsx"],
  AgentMessageRow: [
    "src/agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "src/agent-session/acpmux/conversation/AgentMessageBody.tsx",
    "src/agent-session/acpmux/conversation/MessageCard.tsx",
  ],
  Markdown: ["src/agent-session/acpmux/conversation/Markdown.tsx"],
};

const webviews = path.resolve(import.meta.dir, "..");
const repo = path.resolve(webviews, "..");
const work = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "home-pane-imports-"));
const shipped = path.join(work, "pages");
const mapped = path.join(work, "pages-maps");
const cleanup = () => {
  if (process.env.KEEP !== "1") fs.rmSync(work, { recursive: true, force: true });
  else console.log(`trees kept in ${work}`);
};

const median = (values: readonly number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length === 0 ? NaN : sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
};
const stat = (values: readonly number[], digits = 0) =>
  values.length === 0
    ? "n/a"
    : `${median(values).toFixed(digits)} [${Math.min(...values).toFixed(digits)} to ${Math.max(...values).toFixed(digits)}]`;
const kb = (bytes: number) => `${(bytes / 1024).toFixed(1)} KB`;

/// Files reachable from `entry` over static edges (JS imports, CSS @import, url()), skipping `cut(from, to)` edges.
function reach(meta: Metafile, entry: string, cut: (from: string, to: string) => boolean = () => false) {
  const seen = new Set([entry]);
  const queue = [entry];
  for (let index = 0; index < queue.length; index += 1) {
    const from = queue[index]!;
    for (const edge of meta.inputs[from]?.imports ?? []) {
      if (edge.external || seen.has(edge.path) || edge.kind === "dynamic-import") continue;
      if (cut(from, edge.path)) continue;
      seen.add(edge.path);
      queue.push(edge.path);
    }
  }
  return seen;
}
const intoPane = (from: string, to: string) => !from.startsWith(PANE) && to.startsWith(PANE);
/// Bytes of `inputs` in `outputs` of `meta`.
const bytesIn = (meta: Metafile, outputs: readonly string[], inputs: ReadonlySet<string>) => {
  let sum = 0;
  for (const output of outputs)
    for (const [input, { bytesInOutput }] of Object.entries(meta.outputs[output]?.inputs ?? {}))
      if (inputs.has(input)) sum += bytesInOutput;
  return sum;
};
const minus = (all: ReadonlySet<string>, kept: ReadonlySet<string>) =>
  new Set([...all].filter((one) => !kept.has(one)));

try {
  // 1. The shipped tree and its metafile.
  const metaFile = path.join(work, "metafile.json");
  console.log(`building the pages (scripts/cmux-next/build-pages-web.sh --out ${shipped})`);
  execFileSync(path.join(repo, "scripts/cmux-next/build-pages-web.sh"), ["--out", shipped], {
    stdio: ["ignore", "ignore", "inherit"],
    env: { ...process.env, CMUX_PAGES_METAFILE: metaFile },
  });
  const meta = JSON.parse(fs.readFileSync(metaFile, "utf8")) as Metafile;
  const script = fs.readFileSync(path.join(repo, "scripts/cmux-next/build-pages-web.sh"), "utf8");
  const allPages = [...script.matchAll(/^PAGES="([^"]*)"/gm)].flatMap((match) =>
    match[1]!.split(/\s+/).filter((word) => word && word !== "$PAGES"),
  );
  for (const page of PAGES) if (!allPages.includes(page)) throw new Error(`build-pages-web.sh builds no page ${page}`);

  // The same JS pass with source maps (bundle.mjs's options), over every page so the chunks split alike.
  const srcRoot = path.join(webviews, "src");
  const mappedBuild = await build({
    entryPoints: Object.fromEntries(
      allPages.map((page) => [`${page}/app`, path.join(srcRoot, "pages", page, "main.tsx")]),
    ),
    outdir: mapped,
    absWorkingDir: webviews,
    bundle: true,
    splitting: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    define: { "process.env.NODE_ENV": '"production"' },
    minify: true,
    legalComments: "none",
    loader: { ".png": "dataurl", ".woff2": "dataurl" },
    alias: { shiki: path.join(srcRoot, "agent-session/acpmux/shiki") },
    chunkNames: "__shared/[name]-[hash]",
    logLevel: "error",
    metafile: true,
    sourcemap: "linked",
    plugins: [
      reactCompilerPlugin({ mode: reactCompilerMode(), srcRoot, onCompiled: () => {}, onDiagnostic: () => {} }),
      artifactRuntimePlugin({}),
      tailwindPlugin,
      createJsonParsePlugin({ settingsPageOnly: true }),
      katexStylePlugin({ split: false }),
    ] as Plugin[],
  });
  // The page's app.js and every chunk it statically imports. The shipped metafile names the script's scratch
  // directory, so the entry is found by its tail.
  const eager = (metafile: Metafile, page: string) => {
    const entry = Object.keys(metafile.outputs).find((file) => file.endsWith(`/${page}/app.js`));
    if (!entry) throw new Error(`no ${page}/app.js in the build`);
    const queue = [entry];
    for (let index = 0; index < queue.length; index += 1)
      for (const item of metafile.outputs[queue[index]!]!.imports)
        if (item.kind === "import-statement" && !item.external && !queue.includes(item.path)) queue.push(item.path);
    return queue;
  };
  for (const page of PAGES) {
    const html = fs.readFileSync(path.join(shipped, page, "index.html"), "utf8");
    const outputs = eager(mappedBuild.metafile!, page);
    const links = outputs
      .slice(1)
      .map(
        (file) =>
          `<link rel="modulepreload" href="${path.relative(path.join(mapped, page), path.resolve(webviews, file))}" />`,
      )
      .join("\n");
    const rewritten = html.replace(/(?:<link rel="modulepreload"[^>]*>\n)+/, `${links}\n`);
    if (outputs.length > 1 && rewritten === html) throw new Error(`${page}/index.html holds no modulepreload links`);
    fs.writeFileSync(path.join(mapped, page, "index.html"), rewritten);
    for (const dir of ["locales", "pane-locales"])
      if (fs.existsSync(path.join(shipped, page, dir)))
        fs.cpSync(path.join(shipped, page, dir), path.join(mapped, page, dir), { recursive: true });
  }
  fs.copyFileSync(path.join(shipped, "__shared/page-base.css"), path.join(mapped, "__shared/page-base.css"));

  // 2. Bytes.
  type PageBytes = {
    eagerJs: number;
    paneJs: number;
    eagerCss: number;
    paneCss: number;
    mappedEagerJs: number;
    groups: Record<string, { js: number; css: number }>;
    top: { file: string; js: number }[];
    paneFiles: string[];
  };
  const bytes: Record<string, PageBytes> = {};
  for (const page of PAGES) {
    const entry = `src/pages/${page}/main.tsx`;
    if (!meta.inputs[entry]) throw new Error(`the metafile has no ${entry}`);
    const outputs = eager(meta, page);
    const all = reach(meta, entry);
    const pane = minus(all, reach(meta, entry, intoPane));
    // The page's CSS, as bundle.mjs's isolated pass compiles it.
    const styles = await build({
      entryPoints: [path.join(srcRoot, "pages", page, "main.tsx")],
      outfile: path.join(work, "styles", page, "styles.js"),
      absWorkingDir: webviews,
      bundle: true,
      write: false,
      format: "esm",
      platform: "browser",
      target: "es2022",
      define: { "process.env.NODE_ENV": '"production"' },
      minify: true,
      legalComments: "none",
      loader: { ".png": "dataurl", ".woff2": "dataurl" },
      alias: { shiki: path.join(srcRoot, "agent-session/acpmux/shiki") },
      logLevel: "error",
      metafile: true,
      plugins: [
        artifactRuntimePlugin(),
        tailwindPlugin,
        createJsonParsePlugin({ settingsPageOnly: true }),
        katexStylePlugin({ split: false }),
      ] as Plugin[],
    });
    const cssMeta = styles.metafile!;
    const cssOutputs = Object.keys(cssMeta.outputs).filter((file) => file.endsWith(".css"));
    const cssAll = reach(cssMeta, entry);
    const cssPane = minus(cssAll, reach(cssMeta, entry, intoPane));
    const groups: PageBytes["groups"] = {};
    for (const [name, files] of [...Object.entries(GROUPS), ["all three", Object.values(GROUPS).flat()] as const]) {
      const cut = (from: string, to: string) => !from.startsWith(PANE) && files.includes(to);
      groups[name] = {
        js: bytesIn(meta, outputs, minus(all, reach(meta, entry, cut))),
        css: bytesIn(cssMeta, cssOutputs, minus(cssAll, reach(cssMeta, entry, cut))),
      };
    }
    const imported = new Set<string>();
    for (const from of all)
      if (!from.startsWith(PANE))
        for (const edge of meta.inputs[from]?.imports ?? [])
          if (edge.kind !== "dynamic-import" && edge.path.startsWith(PANE)) imported.add(edge.path);
    const top = [...imported]
      .map((file) => ({
        file,
        js: bytesIn(
          meta,
          outputs,
          minus(
            all,
            reach(meta, entry, (from, to) => !from.startsWith(PANE) && to === file),
          ),
        ),
      }))
      .sort((a, b) => b.js - a.js)
      .slice(0, 12);
    bytes[page] = {
      eagerJs: outputs.reduce((sum, file) => sum + meta.outputs[file]!.bytes, 0),
      paneJs: bytesIn(meta, outputs, pane),
      eagerCss: cssOutputs.reduce((sum, file) => sum + cssMeta.outputs[file]!.bytes, 0),
      paneCss: bytesIn(cssMeta, cssOutputs, cssPane),
      mappedEagerJs: eager(mappedBuild.metafile!, page).reduce(
        (sum, file) => sum + mappedBuild.metafile!.outputs[file]!.bytes,
        0,
      ),
      groups,
      top,
      paneFiles: [...pane],
    };
    const row = bytes[page]!;
    console.log(
      `\n${page} eager load: JS ${kb(row.eagerJs)} (${outputs.length} files), of it pane code ${kb(row.paneJs)} ` +
        `(${((100 * row.paneJs) / row.eagerJs).toFixed(1)}%, ${pane.size} files); CSS ${kb(row.eagerCss)}, of it pane ${kb(row.paneCss)}. ` +
        `Source-mapped copy's eager JS ${kb(row.mappedEagerJs)}.`,
    );
    for (const [name, group] of Object.entries(groups))
      console.log(`  cutting only ${name}: JS -${kb(group.js)}, CSS -${kb(group.css)}`);
    console.log(`  pane files imported by the page, by JS removed when only that import is cut:`);
    for (const one of top) console.log(`    ${kb(one.js).padStart(9)}  ${one.file}`);
  }

  // 3. Script ms.
  const serve = (dir: string) =>
    Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request) {
        const rel = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "");
        const file = path.resolve(dir, rel);
        if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile())
          return new Response("not found", { status: 404 });
        const type = file.endsWith(".js")
          ? "text/javascript; charset=utf-8"
          : file.endsWith(".html")
            ? "text/html; charset=utf-8"
            : file.endsWith(".css")
              ? "text/css; charset=utf-8"
              : "application/octet-stream";
        return new Response(Bun.file(file), { headers: { "content-type": type, "cache-control": "no-store" } });
      },
    });
  const shippedServer = serve(shipped);
  const mappedServer = serve(mapped);
  const PROBE = `(() => {
    const marks = (window.__hp = { changedAt: 0, shifts: 0, shiftScore: 0 });
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.hadRecentInput) continue;
          marks.shifts += 1;
          marks.shiftScore += entry.value;
          (marks.shiftLog ??= []).push({ t: Math.round(entry.startTime), v: +entry.value.toFixed(4), src: (entry.sources || []).map((one) => { const n = one.node; const d = n && n.nodeType === 1 ? n.tagName.toLowerCase() + (n.className && typeof n.className === "string" ? "." + n.className.trim().split(/\\s+/).join(".") : "") : n ? "#text:" + (n.textContent || "").slice(0, 30) : "?"; const r = (x) => [Math.round(x.x), Math.round(x.y), Math.round(x.width), Math.round(x.height)].join(","); return d + " " + r(one.previousRect) + " -> " + r(one.currentRect); }) });
        }
      }).observe({ type: "layout-shift", buffered: true });
    } catch {}
    new MutationObserver(() => {
      marks.changedAt = performance.now();
      if (marks.ready === undefined && document.querySelector('[contenteditable="true"]')) marks.ready = performance.now();
    }).observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
  })();`;
  type Marks = { ready?: number; changedAt: number; shifts: number; shiftScore: number };
  const settle = async (page: import("playwright").Page) => {
    await page.waitForFunction(
      (quiet) => {
        const marks = (window as unknown as { __hp: Marks }).__hp;
        return document.readyState === "complete" && performance.now() - marks.changedAt > quiet;
      },
      SETTLE_MS,
      { timeout: 120_000, polling: 50 },
    );
    return page.evaluate(() => (window as unknown as { __hp: Marks }).__hp);
  };
  const scriptMs = async (cdp: CDPSession) => {
    const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
    return (metrics.find((metric) => metric.name === "ScriptDuration")?.value ?? 0) * 1000;
  };
  type Timing = {
    page: string;
    readyMs: number | null;
    readyScriptMs: number | null;
    settledMs: number;
    settledScriptMs: number;
    shifts: number;
    shiftScore: number;
  };
  type Profiled = { page: string; paneSelfMs: number; allSelfMs: number; idleMs: number };
  const timings: Timing[] = [];
  const profiles: Profiled[] = [];
  const mapper = sourceMapper(mapped);
  const paneAbs = new Map(
    PAGES.map((page) => [page, new Set(bytes[page]!.paneFiles.map((file) => path.resolve(webviews, file)))]),
  );
  const resolveSource = new Map<string, string>();
  try {
    for (let round = 0; round < ROUNDS + 1; round += 1) {
      for (const page of round % 2 ? [...PAGES].reverse() : PAGES) {
        // Timing, on the shipped tree. Round 0 is a warm-up for the OS file cache, not counted.
        {
          const browser = await chromium.launch({ headless: true });
          try {
            const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
            const tab = await context.newPage();
            const cdp = await context.newCDPSession(tab);
            await cdp.send("Performance.enable");
            if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
            await tab.addInitScript(PROBE);
            let readyScriptMs: number | null = null;
            const readyWatch = tab
              .waitForFunction(() => (window as unknown as { __hp: Marks }).__hp.ready !== undefined, null, {
                timeout: 120_000,
                polling: "raf",
              })
              .then(async () => (readyScriptMs = await scriptMs(cdp)))
              .catch(() => undefined);
            await tab.goto(`http://127.0.0.1:${shippedServer.port}/${page}/index.html?mock`, { waitUntil: "commit" });
            const marks = await settle(tab);
            const settledScriptMs = await scriptMs(cdp);
            await Promise.race([readyWatch, Bun.sleep(10)]);
            await requireProductionReact(tab, { dev: false });
            const timing: Timing = {
              page,
              readyMs: marks.ready ?? null,
              readyScriptMs: marks.ready === undefined ? null : readyScriptMs,
              settledMs: marks.changedAt,
              settledScriptMs,
              shifts: marks.shifts,
              shiftScore: marks.shiftScore,
            };
            if ((marks as { shiftLog?: unknown }).shiftLog) console.log(`shift log ${page}: ${JSON.stringify((marks as { shiftLog?: unknown }).shiftLog)}`);
            if (process.env.SHOTS && round === 1) {
              fs.mkdirSync(process.env.SHOTS, { recursive: true });
              await tab.screenshot({ path: path.join(process.env.SHOTS, `${page}-settled.png`) });
            }
            if (round > 0) timings.push(timing);
            console.log(`round ${round}${round ? "" : " (warm-up)"} ${page} timing: ${JSON.stringify(timing)}`);
          } finally {
            await browser.close();
          }
        }
        if (round === 0) continue;
        // Profile, on the source-mapped copy.
        const browser = await chromium.launch({ headless: true });
        try {
          const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
          const tab = await context.newPage();
          const cdp = await context.newCDPSession(tab);
          if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
          await tab.addInitScript(PROBE);
          await cdp.send("Profiler.enable");
          await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
          await cdp.send("Profiler.start");
          await tab.goto(`http://127.0.0.1:${mappedServer.port}/${page}/index.html?mock`, { waitUntil: "commit" });
          await settle(tab);
          const { profile } = (await cdp.send("Profiler.stop")) as {
            profile: {
              nodes: {
                id: number;
                callFrame: { url: string; lineNumber: number; columnNumber: number; functionName: string };
              }[];
              samples: number[];
              timeDeltas: number[];
            };
          };
          const pane = paneAbs.get(page)!;
          const kind = new Map<number, "pane" | "code" | "idle" | "other">();
          for (const node of profile.nodes) {
            const { url, lineNumber, columnNumber, functionName } = node.callFrame;
            if (functionName === "(idle)" || functionName === "(program)") {
              kind.set(node.id, functionName === "(idle)" ? "idle" : "other");
              continue;
            }
            if (!url.startsWith("http")) {
              kind.set(node.id, url || functionName === "(garbage collector)" ? "code" : "other");
              continue;
            }
            const rel = new URL(url).pathname.replace(/^\/+/, "");
            if (!rel.endsWith(".js")) {
              kind.set(node.id, "code");
              continue;
            }
            const where = mapper(`../${rel}`, lineNumber, columnNumber).replace(/:\d+$/, "");
            let file = resolveSource.get(where);
            if (file === undefined) {
              // The map's sources are relative to the map, and the mapper drops their leading ../: match by suffix.
              const hit = [...pane].find((one) => one.endsWith(`/${where}`) || where.endsWith(one.replace(/^\/+/, "")));
              file = hit ?? "";
              resolveSource.set(where, file);
            }
            kind.set(node.id, file && pane.has(file) ? "pane" : "code");
          }
          const sums = { pane: 0, code: 0, idle: 0, other: 0 };
          for (let index = 0; index < profile.samples.length; index += 1)
            sums[kind.get(profile.samples[index]!) ?? "other"] += (profile.timeDeltas[index + 1] ?? 0) / 1000;
          const profiled = { page, paneSelfMs: sums.pane, allSelfMs: sums.pane + sums.code, idleMs: sums.idle };
          profiles.push(profiled);
          console.log(`round ${round} ${page} profile: ${JSON.stringify(profiled)}`);
        } finally {
          await browser.close();
        }
      }
    }
  } finally {
    shippedServer.stop(true);
    mappedServer.stop(true);
  }
  console.log(
    `\nrow 10, Home pages' eager load at CPU ${CPU}x, fresh Chromium per load, medians of ${ROUNDS} [min to max]`,
  );
  for (const page of PAGES) {
    const of = timings.filter((one) => one.page === page);
    const prof = profiles.filter((one) => one.page === page);
    const nums = (values: (number | null)[]) => values.filter((value): value is number => typeof value === "number");
    console.log(
      `  ${page}: ready ${stat(nums(of.map((one) => one.readyMs)))} ms (script ${stat(nums(of.map((one) => one.readyScriptMs)))} ms); ` +
        `settled ${stat(of.map((one) => one.settledMs))} ms (script ${stat(of.map((one) => one.settledScriptMs))} ms); ` +
        `layout shifts ${stat(of.map((one) => one.shifts))} (score ${stat(of.map((one) => one.shiftScore), 4)}); ` +
        `profiled self time in pane code ${stat(
          prof.map((one) => one.paneSelfMs),
          1,
        )} ms of ${stat(prof.map((one) => one.allSelfMs))} ms in all code ` +
        `(${stat(
          prof.map((one) => (100 * one.paneSelfMs) / Math.max(1, one.allSelfMs)),
          1,
        )}%)`,
    );
  }
  const bytesOut = Object.fromEntries(
    Object.entries(bytes).map(([page, { paneFiles, ...rest }]) => [page, { ...rest, paneFileCount: paneFiles.length }]),
  );
  console.log(
    `HOME_PANE_IMPORTS_JSON ${JSON.stringify({ cpu: CPU, rounds: ROUNDS, bytes: bytesOut, timings, profiles })}`,
  );
} finally {
  cleanup();
}
