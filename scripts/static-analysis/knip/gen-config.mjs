// Print a knip config (JSON) for one package dir, given as argv[2] relative to the repo root;
// any further args name knip plugins to turn off.
// knip's own plugins find most entries, but our Vite apps start from HTML pages
// (`<script type="module" src=...>`) that knip does not read, and several Vite configs list
// their inputs in ways knip's vite plugin misses. Without these, knip reports most of
// webviews/src as unused. Entries added here:
//   - every module script of every tracked *.html in the package
//   - every string literal ending in .ts/.tsx/.js/.mjs/.html inside a vite.config* file
//     (rolldownOptions.input and friends; html ones are expanded as above)
//   - tests, scripts, benches and dev servers (tooling, not shipped; their own imports count)
// A package's own knip.json/knip.jsonc wins over this: the caller skips generation then.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const pkg = process.argv[2];
if (!pkg) {
  console.error("usage: gen-config.mjs <package dir>");
  process.exit(2);
}
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const pkgAbs = path.resolve(root, pkg);
const tracked = execFileSync("git", ["ls-files", "--", "."], { cwd: pkgAbs, encoding: "utf8" })
  .split("\n")
  .filter(Boolean);

const entries = new Set();
const seenHtml = new Set();
const rel = (abs) => path.relative(pkgAbs, abs).split(path.sep).join("/");

function addHtml(htmlAbs) {
  if (seenHtml.has(htmlAbs) || !existsSync(htmlAbs)) return;
  seenHtml.add(htmlAbs);
  const html = readFileSync(htmlAbs, "utf8");
  for (const m of html.matchAll(/<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/gi)) {
    const src = m[1].split(/[?#]/)[0];
    if (/^(https?:)?\/\//.test(src)) continue;
    const abs = src.startsWith("/") ? path.join(pkgAbs, src) : path.resolve(path.dirname(htmlAbs), src);
    if (existsSync(abs) && abs.startsWith(pkgAbs + path.sep)) entries.add(rel(abs));
  }
}

for (const f of tracked) {
  if (f.endsWith(".html") && !/(^|\/)(dist|build|out)\//.test(f)) addHtml(path.join(pkgAbs, f));
}
function addLiteral(lit, bases) {
  if (lit.includes("*") || lit.includes("${")) return;
  for (const base of bases) {
    const abs = path.resolve(base, lit.replace(/^\//, ""));
    if (!existsSync(abs) || !abs.startsWith(pkgAbs + path.sep)) continue;
    if (abs.endsWith(".html")) addHtml(abs);
    else entries.add(rel(abs));
    return;
  }
}
const FILE_LIT = /["'`\s=(}]((?:\.{0,2}\/)?[A-Za-z0-9_@][A-Za-z0-9_./@-]*\.(?:tsx?|m?js|jsx|html))\b/g;

// Vite configs (rolldownOptions.input) and the package's own build/dev scripts (esbuild and
// Bun.build entry points such as scripts/pages/bundle.mjs).
for (const f of tracked) {
  const isVite = /(^|\/)vite\.config[^/]*\.(m?[jt]s)$/.test(f);
  const isScript = /^((scripts|dev-server|tools)\/.*|[^/]+)\.(m?[jt]s|sh|py)$/.test(f);
  if (!isVite && !isScript) continue;
  const fileAbs = path.join(pkgAbs, f);
  for (const m of readFileSync(fileAbs, "utf8").matchAll(FILE_LIT)) {
    addLiteral(m[1], [pkgAbs, path.dirname(fileAbs)]);
  }
}

// Repo-level build scripts and app code that name a file of this package by path
// (scripts/cmux-next/build-*-web.sh bundling webviews/src/pages/*/main.tsx, Swift loaders).
try {
  const prefix = pkg.replace(/\/$/, "").replace(/[.[\]\\^$+?(){}|]/g, "\\$&");
  const hits = execFileSync(
    "git",
    ["grep", "-ohE", `${prefix}/[A-Za-z0-9_./@-]+\\.(tsx?|m?js|jsx|html)`, "--", ".",
      `:!${pkg}`, ":!*.md", ":!*.tsv", ":!*.json", ":!*.xcstrings", ":!*.txt"],
    { cwd: root, encoding: "utf8", maxBuffer: 64 << 20 },
  );
  for (const hit of new Set(hits.split("\n").filter(Boolean))) {
    addLiteral(hit.slice(pkg.replace(/\/$/, "").length + 1), [pkgAbs]);
  }
} catch {
  // git grep exits 1 when nothing matches.
}

// Hand-kept extra entry globs: scripts/static-analysis/knip/<pkg with / as __>.entries.
const extraFile = path.join(path.dirname(new URL(import.meta.url).pathname), `${pkg.replace(/\/$/, "").replaceAll("/", "__")}.entries`);
const extra = existsSync(extraFile)
  ? readFileSync(extraFile, "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"))
  : [];

// A first-party cmux app (cmux-app.json): src/main.ts is the app, web-src/ the web pane that
// build-web.ts bundles with Bun.build, and root-level .ts files are `bun <file>` tools.
if (existsSync(path.join(pkgAbs, "cmux-app.json"))) {
  extra.push("*.{ts,mjs}", "src/main.ts", "web-src/{main,editor-worker}.ts", "preview/**/*.ts");
}

const config = {
  $schema: "https://unpkg.com/knip@6/schema.json",
  entry: [
    ...[...entries].sort(),
    ...extra,
    "vite.config*.{ts,mts,js,mjs}",
    "{index,main,cli}.{ts,tsx,js,mjs,jsx}",
    "src/{index,main,cli}.{ts,tsx,js,mjs,jsx}",
    "{scripts,bench,dev-server,tools,test,tests,e2e}/**/*.{ts,tsx,js,mjs,cjs,jsx}",
    "**/*.{test,spec,bench}.{ts,tsx,js,mjs}",
    // import.meta.glob targets in webviews: the gallery registry and dev-only modules.
    "**/*.{gallery,dev}.{ts,tsx}",
  ],
  project: ["**/*.{ts,tsx,js,mjs,cjs,jsx}"],
  ignore: ["**/dist/**", "**/build/**", "**/*.d.ts", "**/generated/**", "**/*.generated.*"],
  // argv[3..]: plugins whose config knip could not load (knip.sh retries with them off).
  ...Object.fromEntries(process.argv.slice(3).map((plugin) => [plugin, false])),
};
process.stdout.write(`${JSON.stringify(config, null, 2)}\n`);
