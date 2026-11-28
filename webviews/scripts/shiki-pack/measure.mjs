// Run on Linux via cmux-ci. Both variants use the same production config at this exact head.
// bun scripts/shiki-pack/measure.mjs OUT_DIR [REPETITIONS]
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, gzipSync } from "node:zlib";
import { build } from "esbuild";
import { chromium, webkit } from "playwright";
import { useSystemChrome as configureSystemChrome } from "../../test/support/systemChrome.ts";
import { shikiPackEsbuild } from "./plugin.mjs";

if (process.platform !== "linux") throw new Error("Shiki measurements run on the Linux fleet only");
const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const out = path.resolve(process.argv[2]);
const repetitions = Number(process.argv[3] ?? 12);
assert(Number.isInteger(repetitions) && repetitions > 0 && repetitions <= 100);
await mkdir(out, { recursive: true });
const receipt = {
  head: execFileSync("git", ["rev-parse", "HEAD"], { cwd: webviews, encoding: "utf8" }).trim(),
  repetitions,
  variants: {},
  grammarEquality: [],
  timings: [],
  smoke: [],
  browsers: {},
  decoder: process.env.CMUX_SHIKI_DECODER ?? "native",
};

async function files(root, prefix = "") {
  const result = [];
  for (const entry of await readdir(path.join(root, prefix), { withFileTypes: true })) {
    const relative = path.join(prefix, entry.name);
    if (entry.isDirectory()) result.push(...(await files(root, relative)));
    else if (entry.isFile()) result.push(relative);
  }
  return result.sort();
}

execFileSync("bun", ["scripts/pages/gen-strings.mjs"], { cwd: webviews, stdio: "inherit", timeout: 120_000 });
for (const variant of ["baseline", "control", "gzip"]) {
  const root = path.join(out, variant);
  const command = variant === "baseline" ? "bash" : "bun";
  const args =
    variant === "baseline"
      ? ["../scripts/build-webviews-app.sh", "--skip-checks", "--out", root]
      : ["run", "vp", "build", "--config", "scripts/shiki-pack/benchmark.vite.mjs"];
  const log = execFileSync(command, args, {
    cwd: webviews,
    env: {
      ...process.env,
      CMUX_WEBVIEWS_OUT_DIR: root,
      CMUX_SHIKI_PACK: variant === "gzip" ? "1" : "0",
      CMUX_SHIKI_DECODER: process.env.CMUX_SHIKI_DECODER ?? "native",
    },
    encoding: "utf8",
    timeout: 600_000,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (variant !== "baseline") {
    // The builder's host wrapper does not depend on bundling. Copy its exact bytes from this
    // same-head baseline, then apply the builder's whitespace normalization to both JS/HTML.
    await writeFile(
      path.join(root, "agent-session.html"),
      await readFile(path.join(out, "baseline/agent-session.html")),
    );
    for (const file of ["main.mjs", "agent-session.html", "diff-page.html", "markdown-page.html", "editor-page.html"]) {
      const text = await readFile(path.join(root, file), "utf8");
      await writeFile(path.join(root, file), text.replace(/[ \t]+(?=\r?\n)/g, "").replace(/[ \t]+$/, ""));
    }
  }
  await writeFile(path.join(out, `${variant}-build.log`), log);
  const inventory = [];
  for (const file of await files(root)) {
    const bytes = await readFile(path.join(root, file));
    inventory.push({ file, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
  }
  receipt.variants[variant] = { bytes: inventory.reduce((sum, item) => sum + item.bytes, 0), inventory };
  if (variant === "control") {
    assert.deepEqual(inventory, receipt.variants.baseline.inventory, "config wrapper changes production output");
    continue;
  }
  const oracle = path.join(out, `oracle-${variant}`);
  await build({
    entryPoints: [path.join(webviews, "scripts/shiki-pack/oracle.mjs")],
    outdir: oracle,
    bundle: true,
    splitting: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    minify: true,
    plugins: variant === "gzip" ? [shikiPackEsbuild()] : [],
  });
  await writeFile(path.join(oracle, "index.html"), '<!doctype html><script type="module" src="./oracle.js"></script>');
}
const originalFiles = new Map(receipt.variants.baseline.inventory.map((item) => [item.file, item]));
for (const item of receipt.variants.gzip.inventory) {
  if (item.file === "chunks/shiki-pack-inflate.mjs" || /\/shiki-lang-.*\.mjs$/.test(item.file)) continue;
  assert.deepEqual(item, originalFiles.get(item.file), `non-grammar production file changed: ${item.file}`);
}
assert.deepEqual(
  receipt.variants.gzip.inventory.map(({ file }) => file).filter((file) => file !== "chunks/shiki-pack-inflate.mjs"),
  receipt.variants.baseline.inventory.map(({ file }) => file),
  "grammar packing changes the production chunk graph",
);

// A real package barrel probe: compare the same public export with shaking enabled and disabled.
const core = {};
for (const treeShaking of [true, false]) {
  const result = await build({
    stdin: { contents: 'export { createHighlighterCore } from "@shikijs/core";', resolveDir: webviews },
    bundle: true,
    format: "esm",
    platform: "browser",
    minify: true,
    write: false,
    metafile: true,
    treeShaking,
  });
  core[String(treeShaking)] = result.outputFiles[0].contents.length;
  await writeFile(path.join(out, `core-tree-shaking-${treeShaking}.json`), JSON.stringify(result.metafile));
}
receipt.coreBarrel = core;
const wrapper = await build({
  stdin: { contents: 'export { createHighlighterCore } from "shiki/core";', resolveDir: webviews },
  bundle: true,
  format: "esm",
  platform: "browser",
  minify: true,
  write: false,
  metafile: true,
  treeShaking: true,
});
receipt.coreWrapper = wrapper.outputFiles[0].contents.length;
await writeFile(path.join(out, "core-wrapper-tree-shaking.json"), JSON.stringify(wrapper.metafile));

// Compare native codecs without shipping a second codec or changing the candidate's portable gzip.
const codecs = { jsonBytes: 0, gzipBytes: 0, brotliBytes: 0 };
const packageDir = path.dirname(fileURLToPath(import.meta.resolve("@shikijs/langs/package.json")));
for (const file of (await readdir(path.join(packageDir, "dist"))).filter((name) => name.endsWith(".mjs"))) {
  const source = await readFile(path.join(packageDir, "dist", file), "utf8");
  for (const match of source.matchAll(/JSON\.parse\(("(?:\\.|[^"\\])*")\)/g)) {
    const json = JSON.parse(match[1]);
    codecs.jsonBytes += Buffer.byteLength(json);
    codecs.gzipBytes += gzipSync(json, { level: 9 }).length;
    codecs.brotliBytes += brotliCompressSync(json).length;
  }
}
receipt.codecs = codecs;

const csp =
  "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; worker-src 'self'; connect-src 'none'";
async function serve(root) {
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const file = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
    if (!file.startsWith(`${root}/`)) {
      response.writeHead(403).end();
      return;
    }
    try {
      const body = await readFile(file);
      response
        .writeHead(200, {
          "Content-Type":
            {
              ".html": "text/html",
              ".mjs": "text/javascript",
              ".js": "text/javascript",
              ".css": "text/css",
              ".woff2": "font/woff2",
            }[path.extname(file)] ?? "application/octet-stream",
          "Content-Security-Policy": csp,
          "Cache-Control": "max-age=3600",
        })
        .end(body);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}
const shared = await serve(out);
const base = shared.origin;
// Vite's dynamic CSS preloads use /assets URLs. Each real production page must be
// served at its own origin root, just as the native surface serves its bundle root.
const production = {};
for (const variant of ["baseline", "gzip"]) production[variant] = await serve(path.join(out, variant));
configureSystemChrome(chromium);
try {
  for (const [engine, browserType] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ]) {
    const browser = await browserType.launch({ headless: true });
    receipt.browsers[engine] = browser.version();
    try {
      // All emitted grammars, including rare languages and every upstream embedded dependency,
      // must decode to byte-for-byte equivalent JSON. No source-map or renderedLength estimates.
      const context = await browser.newContext();
      const page = await context.newPage();
      await page.goto(`${base}/oracle-baseline/index.html`);
      const baselineLangs = receipt.variants.baseline.inventory.filter(({ file }) =>
        /\/shiki-lang-.*\.mjs$/.test(file),
      );
      assert(baselineLangs.length > 200, "expected the full bundled language set, not a vacuous smoke");
      assert.deepEqual(
        baselineLangs.map(({ file }) => file),
        receipt.variants.gzip.inventory
          .filter(({ file }) => /\/shiki-lang-.*\.mjs$/.test(file))
          .map(({ file }) => file),
      );
      for (const { file } of baselineLangs) {
        const equal = await page.evaluate(
          async ({ base, file }) => {
            let timer;
            try {
              return await Promise.race([
                Promise.all([import(`${base}/baseline/${file}`), import(`${base}/gzip/${file}`)]).then(
                  ([before, after]) => {
                    // Rolldown can export either a namespace wrapper or its grammar array
                    // after async-module analysis. Compare data, not private export shapes.
                    const grammars = (module) => {
                      const values = [];
                      const visit = (value) => {
                        if (!value || typeof value !== "object") return;
                        if (typeof value.scopeName === "string") values.push(JSON.stringify(value));
                        else for (const child of Object.values(value)) visit(child);
                      };
                      visit(module);
                      return [...new Set(values)].sort();
                    };
                    const original = grammars(before);
                    const packed = grammars(after);
                    return {
                      equal: original.length > 0 && JSON.stringify(original) === JSON.stringify(packed),
                      grammars: original.length,
                    };
                  },
                ),
                new Promise((_, reject) => {
                  timer = setTimeout(() => reject(new Error(`grammar import timed out: ${file}`)), 15_000);
                }),
              ]);
            } finally {
              clearTimeout(timer);
            }
          },
          { base, file },
        );
        assert(equal.equal, `grammar changed: ${file}`);
        receipt.grammarEquality.push({ engine, file, grammars: equal.grammars });
      }
      const smoke = {};
      for (const variant of ["baseline", "gzip"]) {
        await page.goto(`${base}/oracle-${variant}/index.html`);
        await page.waitForFunction(() => typeof window.shikiSmoke === "function", null, { timeout: 30_000 });
        smoke[variant] = await page.evaluate(() => window.shikiSmoke());
        assert(smoke[variant].languages.length > 200);
      }
      assert.deepEqual(smoke.gzip, smoke.baseline, "public language registry/highlighting differs");
      receipt.smoke.push({
        engine,
        languages: smoke.baseline.languages.length,
        aliases: smoke.baseline.aliases.length,
      });
      await context.close();

      const samples = {
        plain: null,
        typescript: "const answer: number = 42;\nexport function hello(name: string) { return `Hello ${name}`; }",
        "emacs-lisp": '(defun hello (name)\n  (message "Hello %s" name))\n',
        cpp: "#include <vector>\ntemplate<typename T> T square(T value) { return value * value; }\n",
        astro: "---\nconst answer: number = 42;\n---\n<style>h1 { color: red }</style>\n<h1>{answer}</h1>",
        cobol:
          '       IDENTIFICATION DIVISION.\n       PROGRAM-ID. HELLO.\n       PROCEDURE DIVISION.\n           DISPLAY "HELLO WORLD".\n           STOP RUN.',
        vue: '<script setup lang="ts">\nconst count: number = 1;\n</script>\n<template><div>{{ count }}</div></template>\n<style scoped>div { color: red }</style>',
      };
      for (let repeat = 0; repeat < repetitions; repeat++) {
        // Alternate order to avoid attributing process warmup or host drift to compression.
        for (const variant of repeat % 2 ? ["gzip", "baseline"] : ["baseline", "gzip"]) {
          for (const [language, code] of Object.entries(samples)) {
            const context = await browser.newContext({ viewport: { width: 1000, height: 800 } });
            const page = await context.newPage();
            const errors = [];
            page.on("pageerror", (error) => errors.push(String(error)));
            page.on("requestfailed", (request) =>
              errors.push(`request failed: ${request.url()}: ${request.failure()?.errorText}`),
            );
            page.on("response", (response) => {
              if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`);
            });
            await page.addInitScript(
              ({ language, code }) => {
                window.webkit = {
                  messageHandlers: {
                    cmuxPage: {
                      async postMessage(message) {
                        const value =
                          message.t === "sub"
                            ? { sub: message.id }
                            : message.op === "cmux.markdown.config"
                              ? {
                                  path: "/pack-bench.md",
                                  hash: "fixture",
                                  text:
                                    language === "plain"
                                      ? "# Grammar benchmark\n\nAn ordinary markdown page.\n"
                                      : `# Grammar benchmark\n\n\`\`\`${language}\n${code}\n\`\`\`\n`,
                                }
                              : message.op === "cmux.markdown.resolveLinks"
                                ? { links: {} }
                                : {};
                        return { t: "ok", id: message.id, value };
                      },
                    },
                  },
                };
                window.__shikiTiming = {};
                window.__shikiLongTasks = [];
                if (PerformanceObserver.supportedEntryTypes.includes("longtask"))
                  new PerformanceObserver((list) =>
                    window.__shikiLongTasks.push(
                      ...list.getEntries().map(({ startTime, duration }) => ({ startTime, duration })),
                    ),
                  ).observe({ type: "longtask", buffered: true });
                const readableEditor = () => {
                  const editor = document.querySelector(".ProseMirror");
                  const heading = editor?.querySelector("h1");
                  if (!editor?.isContentEditable || heading?.textContent !== "Grammar benchmark") return false;
                  const rect = heading.getBoundingClientRect();
                  const style = getComputedStyle(editor);
                  return (
                    rect.width > 0 &&
                    rect.height > 0 &&
                    rect.right > 0 &&
                    rect.bottom > 0 &&
                    rect.left < innerWidth &&
                    rect.top < innerHeight &&
                    style.visibility === "visible" &&
                    Number(style.opacity) > 0 &&
                    style.pointerEvents !== "none"
                  );
                };
                const afterPaint = (key, predicate) => {
                  const check = () => {
                    if (!predicate()) return requestAnimationFrame(check);
                    requestAnimationFrame(() =>
                      requestAnimationFrame(() => {
                        if (!predicate()) return requestAnimationFrame(check);
                        window.__shikiTiming[key] = performance.now();
                      }),
                    );
                  };
                  requestAnimationFrame(check);
                };
                afterPaint("readyPaint", readableEditor);
                if (language !== "plain")
                  afterPaint(
                    "highlightPaint",
                    () => readableEditor() && document.querySelector(".md-code code [style]"),
                  );
                const observer = new MutationObserver(() => {
                  if (!window.__shikiTiming.ready && document.querySelector(".ProseMirror h1"))
                    window.__shikiTiming.ready = performance.now();
                  if (document.querySelector(".md-code code [style]")) {
                    window.__shikiTiming.highlighted = performance.now();
                    observer.disconnect();
                  }
                });
                observer.observe(document, { childList: true, subtree: true, attributes: true });
              },
              { language, code },
            );
            for (const temperature of ["cold", "warm"]) {
              await page.goto(`${production[variant].origin}/markdown-page.html`);
              await page
                .waitForFunction(
                  (language) =>
                    window.__shikiTiming.readyPaint && (language === "plain" || window.__shikiTiming.highlightPaint),
                  language,
                  { timeout: 30_000 },
                )
                .catch(async (error) => {
                  throw new Error(
                    `${variant}/${language}/${temperature}: ${error}; page errors: ${JSON.stringify(errors)}; body: ${(await page.locator("body").innerText()).slice(0, 1000)}`,
                  );
                });
              const timing = await page.evaluate(() => window.__shikiTiming);
              assert(
                Number.isFinite(timing.ready) &&
                  Number.isFinite(timing.readyPaint) &&
                  (language === "plain" ||
                    (Number.isFinite(timing.highlighted) && Number.isFinite(timing.highlightPaint))),
                "missing readiness timing",
              );
              assert.deepEqual(errors, [], `${variant}/${language}/${temperature}`);
              const colors = await page.locator(language === "plain" ? ".ProseMirror h1" : ".md-code code").innerHTML();
              receipt.timings.push({
                variant,
                engine,
                language,
                temperature,
                repeat,
                ...timing,
                colorsHash: createHash("sha256").update(colors).digest("hex"),
                longTasks: await page.evaluate(() => window.__shikiLongTasks),
              });
            }
            await context.close();
          }
        }
      }
      for (const sample of receipt.timings.filter((row) => row.variant === "baseline")) {
        const candidate = receipt.timings.find(
          (row) =>
            row.variant === "gzip" &&
            row.engine === sample.engine &&
            row.language === sample.language &&
            row.temperature === sample.temperature &&
            row.repeat === sample.repeat,
        );
        assert.equal(candidate.colorsHash, sample.colorsHash, `highlighting changed: ${sample.language}`);
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  for (const { server } of [shared, ...Object.values(production)])
    await new Promise((resolve) => server.close(resolve));
  await writeFile(path.join(out, "receipt.json"), JSON.stringify(receipt, null, 2));
}
const quantile = (values, q) => {
  const finite = values.filter(Number.isFinite).sort((a, b) => a - b);
  return finite.length ? finite[Math.ceil(finite.length * q) - 1] : null;
};
const summary = {
  head: receipt.head,
  paintMethod: "two-rAF readiness proxy, not a compositor timestamp",
  browsers: receipt.browsers,
  variants: Object.fromEntries(Object.entries(receipt.variants).map(([name, value]) => [name, value.bytes])),
  languages: new Set(receipt.grammarEquality.map(({ file }) => file)).size,
  coreBarrel: core,
  coreWrapper: receipt.coreWrapper,
  codecs,
  smoke: receipt.smoke,
  timings: [],
};
for (const engine of ["chromium", "webkit"])
  for (const variant of ["baseline", "gzip"])
    for (const language of [...new Set(receipt.timings.map((row) => row.language))])
      for (const temperature of ["cold", "warm"]) {
        const rows = receipt.timings.filter(
          (row) =>
            row.engine === engine &&
            row.variant === variant &&
            row.language === language &&
            row.temperature === temperature,
        );
        summary.timings.push({
          variant,
          engine,
          language,
          temperature,
          readyP50: quantile(
            rows.map((row) => row.ready),
            0.5,
          ),
          readyP95: quantile(
            rows.map((row) => row.ready),
            0.95,
          ),
          highlightP50: quantile(
            rows.map((row) => row.highlighted),
            0.5,
          ),
          highlightP95: quantile(
            rows.map((row) => row.highlighted),
            0.95,
          ),
          readyPaintP50: quantile(
            rows.map((row) => row.readyPaint),
            0.5,
          ),
          readyPaintP95: quantile(
            rows.map((row) => row.readyPaint),
            0.95,
          ),
          highlightPaintP50: quantile(
            rows.map((row) => row.highlightPaint),
            0.5,
          ),
          highlightPaintP95: quantile(
            rows.map((row) => row.highlightPaint),
            0.95,
          ),
          longTaskMax: Math.max(0, ...rows.flatMap((row) => row.longTasks.map(({ duration }) => duration))),
        });
      }
await writeFile(path.join(out, "summary.json"), JSON.stringify(summary, null, 2));
// The broker returns a bounded log tail. Keep every paired metric in that tail even
// when artifact retrieval is temporarily unavailable; raw samples stay in receipt.json.
console.log(
  `SHIKI_SIZE head=${summary.head} bytes=${summary.variants.baseline}->${summary.variants.gzip} files=${receipt.variants.baseline.inventory.length}->${receipt.variants.gzip.inventory.length}`,
);
console.log(
  `SHIKI_CORRECTNESS ${JSON.stringify({ languages: summary.languages, smoke: summary.smoke, browsers: summary.browsers, paintMethod: summary.paintMethod })}`,
);
console.log(`SHIKI_CODECS ${JSON.stringify({ ...codecs, coreBarrel: core, coreWrapper: receipt.coreWrapper })}`);
const metric = (row, name) =>
  [row[`${name}P50`], row[`${name}P95`]].map((value) => (Number.isFinite(value) ? value.toFixed(1) : "-")).join("/");
for (const baseline of summary.timings.filter((row) => row.variant === "baseline")) {
  const gzip = summary.timings.find(
    (row) =>
      row.variant === "gzip" &&
      row.engine === baseline.engine &&
      row.language === baseline.language &&
      row.temperature === baseline.temperature,
  );
  const metrics = ["ready", "highlight", "readyPaint", "highlightPaint"]
    .map((name) => `${name}=${metric(baseline, name)}->${metric(gzip, name)}`)
    .join(" ");
  console.log(
    `SHIKI_TIMING ${baseline.engine}/${baseline.language}/${baseline.temperature} ${metrics} longTask=${baseline.longTaskMax.toFixed(1)}->${gzip.longTaskMax.toFixed(1)} ms(p50/p95)`,
  );
}
