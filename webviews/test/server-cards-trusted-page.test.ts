// SERVER CARDS IS TRUSTED SCRIPT ONLY WHILE IT IS ONLY ITS OWN BUNDLE. The server cards page
// (pages/server-cards: the join consent Allow and the machine-pairing Confirm) asks for security
// decisions, and the decision for manaflow-ai/cmux#37286 trusts it only because it carries no
// third-party content and runs no script but its own bundled modules. The native host enforces a CSP
// header and refuses debug probes; this is the web-side guard that keeps the page's source honest:
// one relative module script in index.html, and nothing reachable from main.tsx that frames, embeds,
// evaluates, writes raw HTML, dynamically imports a computed or remote module, or names a remote URL.
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";

const webviews = path.resolve(import.meta.dir, "..");
const src = path.join(webviews, "src");
const page = path.join(src, "pages/server-cards");

/** Source patterns the page's module graph must not contain (scanned with comments stripped). */
const BANNED: Record<string, RegExp> = {
  "<iframe": /<iframe\b|createElement\(\s*["']iframe["']/i,
  "<object": /<object\b|createElement\(\s*["']object["']/i,
  "<embed": /<embed\b|createElement\(\s*["']embed["']/i,
  "eval(": /\beval\s*\(/,
  "new Function(": /\bnew\s+Function\s*\(/,
  dangerouslySetInnerHTML: /dangerouslySetInnerHTML/,
  ".innerHTML =": /\.innerHTML\s*\+?=(?!=)/,
  "outerHTML =": /\.outerHTML\s*\+?=(?!=)/,
  insertAdjacentHTML: /insertAdjacentHTML/,
  "document.write": /document\.write(ln)?\s*\(/,
  srcdoc: /srcdoc/i,
  "import( non-relative": /\bimport\s*\((?!\s*["']\.\.?\/[^"'`$]*["']\s*\))/,
  "remote URL": /https?:\/\//i,
};

/** Hits that are not loads, each with why it may stay. Keyed `relative/path: pattern`. Keep it short. */
const ALLOWED: Record<string, string> = {
  // Reached through shared/pageClient: the swipe pill sets a constant SVG string literal, no input in it.
  "swipeNavigation/visuals.ts: .innerHTML =": "constant SVG literal, nothing interpolated",
  // The browser mock host's sample invite: a shell line shown as copyable text, never fetched or loaded.
  "pages/server-cards/pairInvite/fixtures.ts: remote URL": "displayed sample install command, not a load",
};

/** Drops comments but keeps string contents (so `"https://..."` is still seen, `// https://` is not). */
function stripComments(text: string, css: boolean): string {
  if (css) return text.replace(/\/\*[\s\S]*?\*\//g, "");
  let out = "";
  for (let i = 0; i < text.length;) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 2;
    } else if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j + 1;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

function scan(text: string, css: boolean): string[] {
  const code = stripComments(text, css);
  return Object.entries(BANNED)
    .filter(([, re]) => re.test(code))
    .map(([name]) => name);
}

function resolve(from: string, spec: string): string | null {
  const base = path.resolve(path.dirname(from), spec);
  const candidates = [base, ...[".ts", ".tsx", ".css", ".json"].map((ext) => base + ext)];
  candidates.push(...["index.ts", "index.tsx"].map((name) => path.join(base, name)));
  return candidates.find((file) => existsSync(file) && statSync(file).isFile()) ?? null;
}

/** Every file under src reachable from main.tsx through relative static imports and re-exports. */
function moduleGraph(entry: string): string[] {
  const seen = new Set<string>();
  const queue = [entry];
  while (queue.length > 0) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    if (file.endsWith(".json")) continue;
    const code = stripComments(readFileSync(file, "utf8"), file.endsWith(".css"));
    const specs = file.endsWith(".css")
      ? [...code.matchAll(/@import\s+(?:url\()?\s*["']([^"']+)["']/g)]
      : [...code.matchAll(/\b(?:from|import)\s*["']([^"']+)["']/g)];
    for (const [, spec] of specs) {
      if (!spec.startsWith(".")) continue; // a bare package ("react") is bundled by the build, not this page
      const target = resolve(file, spec);
      expect(target, `${path.relative(src, file)} imports ${spec}, which does not resolve`).not.toBeNull();
      if (target && target.startsWith(src + path.sep)) queue.push(target);
    }
  }
  return [...seen].sort();
}

test("index.html loads one relative module script and nothing else", () => {
  const html = readFileSync(path.join(page, "index.html"), "utf8").replace(/<!--[\s\S]*?-->/g, "");
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  expect(scripts.length).toBe(1);
  const [, attrs, body] = scripts[0];
  expect(attrs).toMatch(/\btype=["']module["']/);
  expect(attrs).toMatch(/\bsrc=["']\.\.?\/[^"':]+["']/);
  expect(body.trim()).toBe("");
  expect((html.match(/<script\b/gi) ?? []).length).toBe(1);
  expect(html).not.toMatch(/<(iframe|object|embed|base)\b/i);
  expect(html).not.toMatch(/<link\b[^>]*href=["']?(https?:)?\/\//i);
  expect(html).not.toMatch(/https?:\/\//i);
});

test("nothing reachable from server-cards/main.tsx frames, evaluates, writes HTML or names a remote URL", () => {
  const files = moduleGraph(path.join(page, "main.tsx"));
  expect(files.length).toBeGreaterThan(5);
  const hits = files.flatMap((file) =>
    scan(readFileSync(file, "utf8"), file.endsWith(".css")).map((pattern) => `${path.relative(src, file)}: ${pattern}`),
  );
  expect(hits.filter((hit) => !(hit in ALLOWED))).toEqual([]);
  // An entry that no longer matches goes, so the list never covers a hit it was not written for.
  expect(Object.keys(ALLOWED).filter((entry) => !hits.includes(entry))).toEqual([]);
});

test("the scanner flags every banned pattern and ignores comments", () => {
  const samples: Record<string, string> = {
    "<iframe": "<iframe src={x} />",
    "<object": "<object data={x} />",
    "<embed": "<embed src={x} />",
    "eval(": "eval(code)",
    "new Function(": 'new Function("return 1")',
    dangerouslySetInnerHTML: "<div dangerouslySetInnerHTML={{ __html: x }} />",
    ".innerHTML =": "el.innerHTML = x;",
    "outerHTML =": "el.outerHTML = x;",
    insertAdjacentHTML: 'el.insertAdjacentHTML("beforeend", x)',
    "document.write": "document.write(x)",
    srcdoc: "<frame srcDoc={x} />",
    "import( non-relative": "await import(name)",
    "remote URL": 'fetch("https://example.com")',
  };
  expect(Object.keys(samples).sort()).toEqual(Object.keys(BANNED).sort());
  for (const [name, sample] of Object.entries(samples)) expect(scan(sample, false)).toContain(name);
  expect(scan("a { background: url(https://example.com/x.png); }", true)).toEqual(["remote URL"]);
  expect(scan('@import "http://example.com/x.css";', true)).toEqual(["remote URL"]);
  expect(scan('await import("./local")', false)).toEqual([]);
  expect(scan("// eval(x) at https://example.com\n/* <iframe> */ const a = 1;", false)).toEqual([]);
  expect(scan("/* url(https://example.com) */ a { color: red; }", true)).toEqual([]);
});

// The page ships its bundle as a file script (build-pages-web.sh FILE_SCRIPT_PAGES), and the app's
// policy for it allows no inline script. A signed web update built before that (web ABI 4) inlines
// the page's script, which this app would refuse to run, and calls no join consent op; web ABI 5
// keeps each app on the web it can run (plans/cmux-next/web-ota.md, "Native interface").
test("the page's file-script build comes with web ABI 5 or later", () => {
  const build = readFileSync(path.resolve(webviews, "../scripts/cmux-next/build-pages-web.sh"), "utf8");
  expect(build).toMatch(/^FILE_SCRIPT_PAGES="[^"]*\bserver-cards\b[^"]*"$/m);
  const { abi } = JSON.parse(readFileSync(path.join(src, "web-abi.json"), "utf8")) as { abi: number };
  expect(abi).toBeGreaterThanOrEqual(5);
});
