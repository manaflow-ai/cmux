// Splits a page's generated strings table (all locales) into one script per locale, and prints
// the <head> loader that loads English plus the active locale before the page's module runs
// (window.__cmuxStrings). The page then parses two small tables instead of all 21 (R82 first-open
// speed). Used by scripts/cmux-next/build-pages-web.sh for the pages in SPLIT_STRINGS.
//
//   node scripts/pages/split-strings.mjs <strings.json> <out-dir>   # writes <out-dir>/<locale>.js
import fs from "node:fs";
import path from "node:path";

const [, , input, outDir] = process.argv;
const table = JSON.parse(fs.readFileSync(input, "utf8"));
const locales = Object.keys(table);
fs.mkdirSync(outDir, { recursive: true });
for (const locale of locales) {
  const body = JSON.stringify(table[locale]).replace(/<\/script/gi, "<\\/script");
  fs.writeFileSync(
    path.join(outDir, `${locale}.js`),
    `(window.__cmuxStrings = window.__cmuxStrings || {})[${JSON.stringify(locale)}] = ${body};\n`,
  );
}

// The same resolution as strings.ts resolveLocale, over the shipped locales. It runs before the
// app, as a classic script, and writes one same-origin script tag (the strict page CSP allows
// 'self' and inline scripts).
const loader = `<script src="locales/en.js"></script>
<script>(function () {
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
  if (locale !== "en") document.write('<script src="locales/' + locale + '.js"><\\/script>');
})();</script>`;
process.stdout.write(loader);
