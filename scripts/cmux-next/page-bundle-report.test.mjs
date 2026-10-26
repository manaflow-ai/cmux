// Tests of page-bundle-report.mjs over small built trees (the split layout of task 049 and today's
// one-file pages). Run: node --test scripts/cmux-next/page-bundle-report.test.mjs (not in CI).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { CAPS, moduleImports, pageNames, parseHtml, report } from "./page-bundle-report.mjs";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "page-bundle-report.mjs");
const REACT = 'var e={};e.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE={H:null};export{e as R};\n';
const SHARED = "cmux-page://cmux.shared/react-AB12.js";

const work = mkdtempSync(join(tmpdir(), "page-bundle-report-"));
after(() => rmSync(work, { recursive: true, force: true }));

function tree(name, files) {
  const root = join(work, name);
  for (const [path, body] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), body);
  }
  return {
    pages: join(root, "pages"),
    agentPane: join(root, "agent-pane"),
    agentActivity: join(root, "agent-activity"),
    webviewsApp: join(root, "webviews-app"),
  };
}

const size = (trees, path) => statSync(join(trees.pages, path)).size;
const html = (head, body = "") =>
  `<!doctype html>\n<html>\n<head>\n${head}\n</head>\n<body>\n<main id="root"></main>\n${body}\n</body>\n</html>\n`;

// The split build: a shared React chunk from cmux.shared, a page entry and a lazy section.
const splitPage = {
  "index.html": html(`<link rel="modulepreload" href="${SHARED}" />`, '<script type="module" src="app.js"></script>'),
  "app.js": `import{R as r}from"${SHARED}";const s=()=>import("./chunks/section-1.js");console.log(r,s);\n`,
  "chunks/section-1.js": `import{R as r}from"${SHARED}";import"./section-2.js";export const a=r;\n`,
  "chunks/section-2.js": "export const b=1;\n",
};

function prefixed(prefix, files) {
  return Object.fromEntries(Object.entries(files).map(([path, body]) => [`${prefix}/${path}`, body]));
}

test("a split page counts its own and shared bytes, requests, lazy chunks and the React URL", () => {
  const trees = tree("split", { "pages/_shared/react-AB12.js": REACT, ...prefixed("pages/settings", splitPage) });
  const [row] = report(trees, ["settings"]).documents;
  assert.equal(row.missing, false);
  assert.equal(row.ownBytes, size(trees, "settings/app.js"));
  assert.equal(row.sharedBytes, size(trees, "_shared/react-AB12.js"));
  assert.equal(row.inlineBytes, 0);
  assert.equal(row.requests, 2, "the modulepreload and the import of the same chunk are one request");
  assert.equal(row.lazyChunks, 2, "section-1 and the chunk it imports; the shared chunk is already loaded");
  assert.deepEqual(row.react, [SHARED]);
  assert.deepEqual(row.unresolved, []);
});

test("every built document naming the same shared React URL passes the identity check", () => {
  const trees = tree("same-react", {
    "pages/_shared/react-AB12.js": REACT,
    ...prefixed("pages/settings", splitPage),
    ...prefixed("pages/history", splitPage),
  });
  const result = report(trees, ["settings", "history"]);
  assert.ok(!result.findings.some((finding) => finding.startsWith("React URL")), result.findings.join("\n"));
  assert.ok(!result.findings.some((finding) => finding.startsWith("settings:")), result.findings.join("\n"));
  // The trees have no agent pane, viewers or agent activity: the report says so rather than passing.
  assert.ok(result.findings.includes("agent pane: not built (cmux-page://cmux.agent/index.html)"));
  assert.equal(result.pass, false);
});

test("an inline one-file page: inline bytes are its own, its React URL differs, Settings is not lazy", () => {
  const big = `const pad="${"x".repeat(CAPS.ownBytes)}";${REACT}`;
  const trees = tree("inline", {
    "pages/_shared/react-AB12.js": REACT,
    ...prefixed("pages/history", splitPage),
    "pages/settings/index.html": html("", `<script type="module">\n${big}</script>`),
  });
  const result = report(trees, ["history", "settings"]);
  const settings = result.documents.find((row) => row.name === "settings");
  assert.equal(settings.inlineBytes, Buffer.byteLength(`\n${big}`));
  assert.equal(settings.ownBytes, settings.inlineBytes);
  assert.equal(settings.requests, 0);
  assert.deepEqual(settings.react, ["inline #1 in cmux-page://cmux.settings/index.html"]);
  assert.ok(result.findings.some((finding) => /^settings: own JS \d+\.\d KB > 250\.0 KB$/.test(finding)), result.findings.join("\n"));
  assert.ok(result.findings.includes("React URL: 2 different URLs across 2 documents (D8 wants one)"));
  assert.ok(result.findings.some((finding) => finding.startsWith("settings: no lazy chunk")));
});

test("a locale loader adds one request and the largest locale table", () => {
  const loader = `(function(){var locale="en";if (locale !== "en") document.write('<script src="locales/' + locale + '.js"><\\/script>');})();`;
  const trees = tree("locales", {
    "pages/_shared/react-AB12.js": REACT,
    ...prefixed("pages/settings", splitPage),
    "pages/settings/index.html": html(
      `<script src="locales/en.js"></script>\n<script>${loader}</script>`,
      '<script type="module" src="app.js"></script>',
    ),
    "pages/settings/locales/en.js": "window.s={en:1};\n",
    "pages/settings/locales/de.js": "window.s={de:12345};\n",
    "pages/settings/locales/ja.js": "window.s={ja:1};\n",
  });
  const [row] = report(trees, ["settings"]).documents;
  assert.equal(row.requests, 4, "en.js, app.js, the shared chunk it imports and the active locale");
  const own = ["settings/app.js", "settings/locales/en.js", "settings/locales/de.js"].map((path) => size(trees, path));
  assert.equal(row.ownBytes, own.reduce((a, b) => a + b, 0) + Buffer.byteLength(loader));
});

test("a chunk URL that resolves to no built file is a finding", () => {
  const trees = tree("broken", {
    "pages/settings/index.html": html("", '<script type="module" src="app.js"></script>'),
    "pages/settings/app.js": `import"../_shared/react-AB12.js";\n`,
  });
  const result = report(trees, ["settings"]);
  assert.ok(result.findings.includes("settings: cmux-page://cmux.settings/_shared/react-AB12.js does not resolve to a built file"));
});

test("moduleImports reads minified esbuild and Vite imports and skips strings that are not chunks", () => {
  const code =
    'import{a as b,c}from"./chunk-A.js";import*as d from"../x/b.mjs";import"./side.js";export*from"./re.js";' +
    'export{e}from"cmux-page://cmux.shared/s.js";const f=()=>import(`./lazy.mjs`);fetch("/upload");' +
    'const g=t.from("/retry");import("./other.js")';
  assert.deepEqual(moduleImports(code), {
    static: ["./chunk-A.js", "../x/b.mjs", "./side.js", "./re.js", "cmux-page://cmux.shared/s.js"],
    dynamic: ["./lazy.mjs", "./other.js"],
  });
});

test("parseHtml finds scripts and links but not markup inside a script or a style", () => {
  const { scripts, links } = parseHtml(
    html(
      '<link rel="modulepreload" href="a.js"><link rel="stylesheet" href="s.css"><style>/* <link rel="modulepreload" href="no.js"> */</style>',
      '<script type="module">const t=`<link rel="modulepreload" href="no2.js">`;</script><script src="c.js"></script>',
    ),
  );
  assert.deepEqual(links, [
    { href: "a.js", kind: "module" },
    { href: "s.css", kind: "style" },
  ]);
  assert.deepEqual(
    scripts.map(({ src, module }) => ({ src, module })),
    [
      { src: undefined, module: true },
      { src: "c.js", module: false },
    ],
  );
});

test("the page list is build-pages-web.sh's PAGES", () => {
  const names = pageNames();
  assert.ok(names.length >= 17, names.join(" "));
  for (const name of ["settings", "history", "home-channels"]) assert.ok(names.includes(name), name);
});

test("the command prints every D8 field and exits 1 on a finding, 2 on a usage error", () => {
  const trees = tree("cli", { "pages/_shared/react-AB12.js": REACT, ...prefixed("pages/settings", splitPage) });
  const run = spawnSync(process.execPath, [SCRIPT, "--pages", trees.pages, "--agent-pane", trees.agentPane], { encoding: "utf8" });
  assert.equal(run.status, 1);
  for (const field of ["own JS", "shared JS", "total JS", "requests", "lazy", "inline JS", "React URL"]) {
    assert.ok(run.stdout.includes(field), field);
  }
  assert.match(run.stdout, /caps: own <= 250 KB, shared <= 400 KB, total <= 600 KB, requests <= 4/);
  assert.match(run.stdout, /^D8: FAIL \(\d+ findings\)$/m);
  const json = spawnSync(process.execPath, [SCRIPT, "--pages", trees.pages, "--json"], { encoding: "utf8" });
  assert.equal(json.status, 1);
  const result = JSON.parse(json.stdout);
  assert.equal(result.pass, false);
  assert.equal(result.documents.find((row) => row.name === "settings").sharedBytes, size(trees, "_shared/react-AB12.js"));
  const usage = spawnSync(process.execPath, [SCRIPT, "--pages"], { encoding: "utf8" });
  assert.equal(usage.status, 2);
  assert.match(usage.stderr, /--pages needs a directory/);
});
