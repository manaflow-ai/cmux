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
for (const variant of ["baseline", "gzip"]) {
  const root = path.join(out, variant);
  const command = variant === "baseline" ? "bash" : "bun";
  const args =
    variant === "baseline"
      ? ["../scripts/build-webviews-app.sh", "--skip-checks", "--out", root]
      : ["run", "vp", "build", "--config", "scripts/shiki-pack/benchmark.vite.mjs"];
  const log = execFileSync(command, args, {
    cwd: webviews,
    env: { ...process.env, CMUX_WEBVIEWS_OUT_DIR: root, CMUX_SHIKI_PACK: variant === "gzip" ? "1" : "0" },
    encoding: "utf8",
    timeout: 600_000,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (variant === "gzip") {
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
const server = createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  const file = path.resolve(out, `.${decodeURIComponent(url.pathname)}`);
  if (!file.startsWith(`${out}/`)) {
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
const base = `http://127.0.0.1:${server.address().port}`;
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
      await page.goto(`${base}/baseline/markdown-page.html`);
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
        typescript: "const answer: number = 42;\nexport function hello(name: string) { return `Hello ${name}`; }",
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
                                  text: `# Grammar benchmark\n\n\`\`\`${language}\n${code}\n\`\`\`\n`,
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
              await page.goto(`${base}/${variant}/markdown-page.html`);
              await page.waitForFunction(() => window.__shikiTiming.highlighted, null, { timeout: 30_000 });
              const timing = await page.evaluate(() => window.__shikiTiming);
              assert(Number.isFinite(timing.ready) && Number.isFinite(timing.highlighted), "missing readiness timing");
              assert.deepEqual(errors, [], `${variant}/${language}/${temperature}`);
              const colors = await page.locator(".md-code code").innerHTML();
              receipt.timings.push({
                variant,
                engine,
                language,
                temperature,
                repeat,
                ...timing,
                colorsHash: createHash("sha256").update(colors).digest("hex"),
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
  await new Promise((resolve) => server.close(resolve));
  await writeFile(path.join(out, "receipt.json"), JSON.stringify(receipt, null, 2));
}
const quantile = (values, q) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * q) - 1];
const summary = {
  head: receipt.head,
  browsers: receipt.browsers,
  variants: Object.fromEntries(Object.entries(receipt.variants).map(([name, value]) => [name, value.bytes])),
  languages: new Set(receipt.grammarEquality.map(({ file }) => file)).size,
  coreBarrel: core,
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
        });
      }
await writeFile(path.join(out, "summary.json"), JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));
