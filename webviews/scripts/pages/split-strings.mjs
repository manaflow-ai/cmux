// Splits a page's generated strings table (all locales) into one script per locale, and prints
// the <head> loader that loads English plus the active locale before the page's module runs
// (window.__cmuxStrings). The page then parses two small tables instead of all 21 (R82 first-open
// speed). Used by scripts/cmux-next/build-pages-web.sh for the pages in SPLIT_STRINGS, and by the
// agent pane's Vite build (vite.config.acpmux-pane.mjs) so the benches load strings as the app does.
//
//   node scripts/pages/split-strings.mjs <strings.json> <out-dir> [global] [--loader-file]
// writes <out-dir>/<locale>.js. `global` names the window property the scripts fill (default
// __cmuxStrings; the agent pane uses __cmuxPaneStrings). With --loader-file the loader is
// <out-dir>/loader.js and the printed tags are two same-origin script files, for a page whose CSP
// allows no inline script (the agent pane: script-src 'self').
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/// The per-locale scripts and the loader for `table`, served from `dir` beside the page: `files`
/// maps a file name in `dir` (`<locale>.js`, `loader.js`) to its text; `tags` is the <head> markup.
export function splitStrings(table, { global = "__cmuxStrings", dir = "locales", loaderFile = false } = {}) {
  if (!/^[A-Za-z_$][\w$]*$/.test(global)) throw new Error(`not a property name: ${global}`);
  const locales = Object.keys(table);
  const files = {};
  for (const locale of locales) {
    const body = JSON.stringify(table[locale]).replace(/<\/script/gi, "<\\/script");
    files[`${locale}.js`] = `(window.${global} = window.${global} || {})[${JSON.stringify(locale)}] = ${body};\n`;
  }
  // The same resolution as strings.ts resolveLocale, over the shipped locales. It runs before the
  // app, as a classic script, and writes one same-origin script tag (document.write from a
  // parser-blocking script, so the locale runs before the page's module).
  const select = `(function () {
  var known = ${JSON.stringify(locales)};
  var tag = (navigator.language || "en").replace(/_/g, "-");
  var parts = tag.split("-"), lang = parts[0].toLowerCase(), rest = parts.slice(1);
  var candidates = [tag];
  if (lang === "zh") candidates.push(rest.some(function (p) { return /^(hant|tw|hk|mo)$/i.test(p); }) ? "zh-Hant" : "zh-Hans");
  if (lang === "pt") candidates.push("pt-BR");
  if (lang === "no" || lang === "nn") candidates.push("nb");
  candidates.push(lang);
  var locale = "en";
  for (var i = 0; i < candidates.length; i++) if (known.indexOf(candidates[i]) >= 0) { locale = candidates[i]; break; }
  document.documentElement.lang = locale;
  if (locale !== "en") document.write('<script src="${dir}/' + locale + '.js"><\\/script>');
})();`;
  if (loaderFile) {
    files["loader.js"] = `${select}\n`;
    return { files, tags: `<script src="${dir}/en.js"></script>\n<script src="${dir}/loader.js"></script>` };
  }
  return { files, tags: `<script src="${dir}/en.js"></script>\n<script>${select}</script>` };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const loaderFile = args.includes("--loader-file");
  const [input, outDir, global = "__cmuxStrings"] = args.filter((arg) => arg !== "--loader-file");
  const table = JSON.parse(fs.readFileSync(input, "utf8"));
  const { files, tags } = splitStrings(table, { global, dir: path.basename(outDir), loaderFile });
  fs.mkdirSync(outDir, { recursive: true });
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(outDir, name), text);
  process.stdout.write(tags);
}
