// Compiles every first-party .ts/.tsx file under src/ with both React Compilers that
// CMUX_REACT_COMPILER selects between (reactCompiler.mjs) and compares the output, so a
// switch of the default can be judged on the whole tree.
//
//   bun scripts/react-compiler-diff.mjs [--out <dir>]
//
// Both sides are printed through the same printer: Babel's output (which keeps TypeScript)
// has its types stripped by Oxc with the compiler off, then esbuild prints both as JSX.
// Files whose printed output differs are listed with each compiled function's cache size
// (`_c(n)`) and a kind: "naming" when the two differ only in comments and binding names, else
// "memoization". --out writes the two versions of each differing file for diffing.
import { transformAsync } from "@babel/core";
import { transform } from "esbuild";
import { transformSync } from "oxc-transform-react";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { REACT_COMPILER_TARGET } from "../reactCompiler.mjs";

const srcRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../src");
const outIndex = process.argv.indexOf("--out");
const outDir = outIndex >= 0 ? path.resolve(process.argv[outIndex + 1]) : undefined;
if (outDir) mkdirSync(outDir, { recursive: true });

const files = readdirSync(srcRoot, { recursive: true })
  .map((name) => path.join(srcRoot, String(name)))
  .filter((file) => /\.tsx?$/.test(file) && !file.endsWith(".d.ts") && !/\.test\.tsx?$/.test(file))
  .filter((file) => !file.split(path.sep).includes("generated"))
  .sort();

const lang = (file) => (file.endsWith(".tsx") ? "tsx" : "ts");
const cacheSizes = (code) => [...code.matchAll(/\b_c\d*\((\d+)\)/g)].map((match) => Number(match[1]));
// Comparison only: drop line comments and the numeric suffixes each compiler gives renamed
// bindings and hoisted temporaries (`event_0`, `value2`, `_temp10`, `t12`), so two outputs that
// differ only in names compare equal. Cache slot indices (`$[3]`) and sizes are kept.
const naming = (code) =>
  code
    .replace(/^\s*\/\/.*\n|^\s*\/\*\*.*\*\/\n|^\s*;\n/gm, "")
    .replace(/\b([A-Za-z_$][\w$]*?)_?\d+\b/g, "$1")
    .replace(/([\w$]+): \1\b/g, "$1");
const print = async (code) => (await transform(code, { loader: "jsx", format: "esm", legalComments: "none" })).code;

let babelMs = 0;
let oxcMs = 0;
let compiledFiles = 0;
const differing = [];
for (const file of files) {
  const source = readFileSync(file, "utf8");
  const relative = path.relative(srcRoot, file);
  let start = performance.now();
  const babel = await transformAsync(source, {
    filename: file,
    babelrc: false,
    configFile: false,
    parserOpts: { plugins: ["jsx", "typescript"] },
    plugins: [["babel-plugin-react-compiler", { target: REACT_COMPILER_TARGET }]],
  });
  babelMs += performance.now() - start;
  start = performance.now();
  const oxc = transformSync(file, source, {
    lang: lang(file),
    jsx: "preserve",
    reactCompiler: { target: REACT_COMPILER_TARGET },
  });
  oxcMs += performance.now() - start;
  const babelJs = transformSync(file, babel?.code ?? "", { lang: lang(file), jsx: "preserve", reactCompiler: false });
  if (oxc.fatal || babelJs.fatal) {
    differing.push({ relative, fatal: true });
    continue;
  }
  const [babelOut, oxcOut] = [await print(babelJs.code), await print(oxc.code)];
  const babelSizes = cacheSizes(babelOut);
  const oxcSizes = cacheSizes(oxcOut);
  if (babelSizes.length || oxcSizes.length) compiledFiles++;
  if (babelOut === oxcOut) continue;
  const kind = naming(babelOut) === naming(oxcOut) ? "naming" : "memoization";
  differing.push({ relative, kind, babelSizes, oxcSizes });
  if (outDir) {
    const base = path.join(outDir, relative.replaceAll(path.sep, "__"));
    writeFileSync(`${base}.babel.jsx`, babelOut);
    writeFileSync(`${base}.oxc.jsx`, oxcOut);
  }
}

console.log(
  `${files.length} files, ${compiledFiles} with compiler output, ${differing.length} differ ` +
    `(babel ${Math.round(babelMs)} ms, oxc ${Math.round(oxcMs)} ms)`,
);
for (const item of differing) {
  if (item.fatal) console.log(`  ${item.relative}: fatal`);
  else
    console.log(
      `  ${item.kind} ${item.relative}: babel [${item.babelSizes.join(",")}] oxc [${item.oxcSizes.join(",")}]`,
    );
}
