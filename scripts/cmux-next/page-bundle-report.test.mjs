// Tests of page-bundle-report.mjs over small built trees (the split layout of task 049 and today's
// one-file pages). Run: node --test scripts/cmux-next/page-bundle-report.test.mjs (not in CI).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  CAPS,
  compareWithBaseline,
  moduleImports,
  pageNames,
  parseHtml,
  report,
  sectionChunks,
  settingsSections,
} from "./page-bundle-report.mjs";

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

// The split build: a shared React chunk from cmux.shared, a page entry and two lazy sections, each
// in the chunk esbuild names after its module (Theme-<hash>.js), one with a chunk of its own.
const splitPage = {
  "index.html": html(`<link rel="modulepreload" href="${SHARED}" />`, '<script type="module" src="app.js"></script>'),
  "app.js":
    `import{R as r}from"${SHARED}";const s=()=>import("./chunks/Theme-QW12ER34.js");` +
    `const t=()=>import("./chunks/Accounts-ZX56CV78.js");console.log(r,s,t);\n`,
  "chunks/Theme-QW12ER34.js": `import{R as r}from"${SHARED}";import"./chunk-AB12CD34.js";export const a=r;\n`,
  "chunks/chunk-AB12CD34.js": "export const b=1;\n",
  "chunks/Accounts-ZX56CV78.js": "export const c=1;\n",
};

// The same page with each section in one file: Theme's chunk is in the first load.
const onePerSection = {
  ...splitPage,
  "app.js": `import"./chunks/chunk-AB12CD34.js";${splitPage["app.js"]}`,
};

// The Settings sections of the fixtures: two lazy ones and a third lazySections.ts does not name.
const SECTIONS = {
  sections: [
    { id: "theme", chunk: "Theme" },
    { id: "accounts", chunk: "Accounts" },
    { id: "general", chunk: null },
  ],
  problems: [],
};

function prefixed(prefix, files) {
  return Object.fromEntries(Object.entries(files).map(([path, body]) => [`${prefix}/${path}`, body]));
}

test("a split page counts its own and shared bytes, requests, lazy chunks and the React URL", () => {
  const trees = tree("split", { "pages/_shared/react-AB12.js": REACT, ...prefixed("pages/settings", splitPage) });
  const [row] = report(trees, ["settings"], SECTIONS).documents;
  assert.equal(row.missing, false);
  assert.equal(row.ownBytes, size(trees, "settings/app.js"));
  assert.equal(row.sharedBytes, size(trees, "_shared/react-AB12.js"));
  assert.equal(row.inlineBytes, 0);
  assert.equal(row.requests, 2, "the modulepreload and the import of the same chunk are one request");
  assert.equal(row.lazyChunks, 3, "both sections and the chunk Theme imports; the shared chunk is already loaded");
  assert.deepEqual(row.react, [SHARED]);
  assert.deepEqual(row.unresolved, []);
});

test("every built document naming the same shared React URL passes the identity check", () => {
  const trees = tree("same-react", {
    "pages/_shared/react-AB12.js": REACT,
    ...prefixed("pages/settings", onePerSection),
    ...prefixed("pages/history", splitPage),
  });
  const result = report(trees, ["settings", "history"], SECTIONS);
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
  const result = report(trees, ["history", "settings"], SECTIONS);
  const settings = result.documents.find((row) => row.name === "settings");
  assert.equal(settings.inlineBytes, Buffer.byteLength(`\n${big}`));
  assert.equal(settings.ownBytes, settings.inlineBytes);
  assert.equal(settings.requests, 0);
  assert.deepEqual(settings.react, ["inline #1 in cmux-page://cmux.settings/index.html"]);
  assert.ok(result.findings.some((finding) => /^settings: own JS \d+\.\d KB > 250\.0 KB$/.test(finding)), result.findings.join("\n"));
  assert.ok(result.findings.includes("React URL: 2 different URLs across 2 documents (D8 wants one)"));
  assert.ok(
    result.findings.includes(
      "settings: the first load holds 3 sections (D8 wants the navigation and one): theme (no lazy Theme-<hash>.js chunk), " +
        "accounts (no lazy Accounts-<hash>.js chunk), general (not in lazySections.ts)",
    ),
    result.findings.join("\n"),
  );
});

// Every page imports webviews/src/pages/shared/desktop.ts, which loads the glass lens through
// import(), so a Settings page always has a lazy chunk, whether or not its sections are lazy.
test("a lazy chunk that is not a section does not pass the Settings check", () => {
  const trees = tree("lens-only", {
    "pages/_shared/react-AB12.js": REACT,
    "pages/settings/index.html": html("", '<script type="module" src="app.js"></script>'),
    "pages/settings/app.js":
      `import{R as r}from"${SHARED}";import"./_shared/Theme-QW12ER34.js";import"./_shared/Accounts-ZX56CV78.js";` +
      `const l=()=>import("./_shared/lens-N3NMW2K2.js");console.log(r,l);\n`,
    "pages/settings/_shared/Theme-QW12ER34.js": "export const a=1;\n",
    "pages/settings/_shared/Accounts-ZX56CV78.js": "export const b=1;\n",
    "pages/settings/_shared/lens-N3NMW2K2.js": "export const l=1;\n",
  });
  const result = report(trees, ["settings"], SECTIONS);
  assert.equal(result.documents[0].lazyChunks, 1);
  assert.ok(
    result.findings.includes(
      "settings: the first load holds 3 sections (D8 wants the navigation and one): " +
        "theme (cmux-page://cmux.settings/_shared/Theme-QW12ER34.js loads first), " +
        "accounts (cmux-page://cmux.settings/_shared/Accounts-ZX56CV78.js loads first), general (not in lazySections.ts)",
    ),
    result.findings.join("\n"),
  );
  // Today's sources: no lazySections.ts, so the lens chunk does not make the sections lazy.
  const today = report(trees, ["settings"], sectionChunks([{ id: "theme", lead: ["themeStudio"], trail: [] }], null));
  assert.ok(
    today.findings.includes(
      "settings: webviews/src/pages/settings/lazySections.ts is missing, so the first load holds every section",
    ),
    today.findings.join("\n"),
  );
});

test("one section in the first load passes the Settings check, two do not", () => {
  const trees = tree("one-first", { "pages/_shared/react-AB12.js": REACT, ...prefixed("pages/settings", onePerSection) });
  const passing = report(trees, ["settings"], SECTIONS);
  assert.ok(!passing.findings.some((finding) => finding.startsWith("settings:")), passing.findings.join("\n"));
  const sections = { ...SECTIONS, sections: [...SECTIONS.sections, { id: "server", chunk: "Server" }] };
  const failing = report(trees, ["settings"], sections);
  assert.ok(
    failing.findings.includes(
      "settings: the first load holds 2 sections (D8 wants the navigation and one): " +
        "general (not in lazySections.ts), server (no lazy Server-<hash>.js chunk)",
    ),
    failing.findings.join("\n"),
  );
});

// A section's import fetches its chunk, then the chunk's static imports: each file after the first
// is one more round trip before the section paints (task 081: one file per section).
test("a lazy section that loads more than one file after the first load is a finding", () => {
  const trees = tree("waterfall", { "pages/_shared/react-AB12.js": REACT, ...prefixed("pages/settings", splitPage) });
  const result = report(trees, ["settings"], SECTIONS);
  const [row] = result.documents;
  assert.deepEqual(row.lazyLoads, {
    "cmux-page://cmux.settings/chunks/Theme-QW12ER34.js": [
      "cmux-page://cmux.settings/chunks/Theme-QW12ER34.js",
      "cmux-page://cmux.settings/chunks/chunk-AB12CD34.js",
    ],
    "cmux-page://cmux.settings/chunks/Accounts-ZX56CV78.js": ["cmux-page://cmux.settings/chunks/Accounts-ZX56CV78.js"],
  });
  assert.deepEqual(
    result.findings.filter((finding) => finding.startsWith("settings:")),
    [
      "settings: section theme loads 2 files (Theme-QW12ER34.js, chunk-AB12CD34.js) after the first load (task 081 wants one)",
    ],
  );
  // The shared chunk in the first load: Theme paints with its own file.
  const one = tree("one-file", { "pages/_shared/react-AB12.js": REACT, ...prefixed("pages/settings", onePerSection) });
  const fixed = report(one, ["settings"], SECTIONS);
  assert.deepEqual(fixed.findings.filter((finding) => finding.startsWith("settings:")), []);
});

test("sectionChunks reads lazySections.ts entries and adds the schema categories that draw a card", () => {
  const source =
    'export const lazySections = {\n  theme: () => import("./sections/Theme"),\n' +
    "  \"agents\": async () => import('./sections/Agents.tsx'),\n" +
    '  a: () => import("./a/index"),\n  b: () => import("./b/index"),\n};\n';
  const categories = [
    { id: "theme", lead: ["themeStudio"], trail: [] },
    { id: "editor", lead: [], trail: [] },
    { id: "mobile", lead: [], trail: ["mobile"] },
  ];
  assert.deepEqual(sectionChunks(categories, source), {
    sections: [
      { id: "theme", chunk: "Theme" },
      { id: "mobile", chunk: null },
      { id: "agents", chunk: "Agents" },
      { id: "a", chunk: "index" },
      { id: "b", chunk: "index" },
    ],
    problems: ["sections a, b share the chunk name index, so their chunks cannot be told apart"],
  });
  const ids = settingsSections().sections.map((section) => section.id);
  for (const id of ["theme", "accounts", "agents"]) assert.ok(ids.includes(id), ids.join(" "));
  assert.ok(!ids.includes("development"), "a category with no card has no section code");
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

test("a cmux.shared URL resolves only to a .js or .css file under pages/_shared", () => {
  const trees = tree("shared-root", {
    "pages/_shared/react-AB12.js": REACT,
    "pages/_shared/x.mjs": "export const x=1;\n",
    "pages/settings/index.html": html("", '<script type="module" src="app.js"></script>'),
    "pages/settings/app.js":
      'import"cmux-page://cmux.shared/_shared/react-AB12.js";import"cmux-page://cmux.shared/settings/app.js";' +
      `import"cmux-page://cmux.shared/x.mjs";import"${SHARED}";\n`,
  });
  const result = report(trees, ["settings"], SECTIONS);
  for (const path of ["_shared/react-AB12.js", "settings/app.js", "x.mjs"]) {
    const finding = `settings: cmux-page://cmux.shared/${path} does not resolve to a built file`;
    assert.ok(result.findings.includes(finding), `${finding}\n${result.findings.join("\n")}`);
  }
  assert.equal(result.documents[0].sharedBytes, size(trees, "_shared/react-AB12.js"), "only the file the handler serves");
});

test("a chunk URL that resolves to no built file is a finding", () => {
  const trees = tree("broken", {
    "pages/settings/index.html": html("", '<script type="module" src="app.js"></script>'),
    "pages/settings/app.js": `import"../_shared/react-AB12.js";\n`,
  });
  const result = report(trees, ["settings"], SECTIONS);
  assert.ok(result.findings.includes("settings: cmux-page://cmux.settings/_shared/react-AB12.js does not resolve to a built file"));
});

test("--baseline compares each document's total and requests with a base report's", () => {
  const row = (name, ownBytes, sharedBytes, requests, missing = false) => ({ name, ownBytes, sharedBytes, requests, missing });
  const base = [row("files", 100, 200, 4), row("stats", 50, 50, 3), row("agent pane", 900, 0, 13), row("diff", 0, 0, 0, true)];
  const head = [row("files", 100, 220, 4), row("stats", 40, 50, 3), row("agent pane", 300, 590, 14), row("diff", 5, 0, 1)];
  assert.deepEqual(compareWithBaseline(base, head), [
    { name: "files", baseBytes: 300, bytes: 320, baseRequests: 4, requests: 4, grew: true },
    { name: "stats", baseBytes: 100, bytes: 90, baseRequests: 3, requests: 3, grew: false },
    { name: "agent pane", baseBytes: 900, bytes: 890, baseRequests: 13, requests: 14, grew: true },
  ]);
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
