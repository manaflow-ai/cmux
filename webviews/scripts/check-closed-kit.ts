/**
 * The closed kit's list holds (RFD 0040): every product .tsx in a directory tsconfig.closed.json lists
 * opens with the closed runtime's pragma (`/** @jsxImportSource <path to src/kit/closed> *\/`), so a file
 * added to a closed directory is closed too, not only the files that were there the day it closed. The
 * pragma is what shuts the doors (src/kit/closed/jsx-runtime.ts); `tsc -p tsconfig.closed.json`, run after
 * this, is what fails on a raw element, `style` or `className`. Tests and galleries (*.test.tsx,
 * *.gallery.tsx) render raw elements to inspect what a piece drew, so they stay open.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CLOSED_RUNTIME = join(ROOT, "src/kit/closed");
const PRAGMA = /^\/\*\* @jsxImportSource (\S+) \*\//;

/** tsconfig.closed.json's `include`, with its // comments dropped. */
function closedDirectories(): string[] {
  const text = readFileSync(join(ROOT, "tsconfig.closed.json"), "utf8").replace(/^\s*\/\/.*$/gm, "");
  const include = (JSON.parse(text) as { include: string[] }).include;
  // Files (the ambient globals a closed file's imports need) are listed for the type check, not closed.
  return include.filter(
    (entry) =>
      entry.startsWith("src/") &&
      resolve(ROOT, entry) !== CLOSED_RUNTIME &&
      statSync(resolve(ROOT, entry)).isDirectory(),
  );
}

function productTsx(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return productTsx(path);
    return name.endsWith(".tsx") && !name.includes(".test.") && !name.includes(".gallery.") ? [path] : [];
  });
}

const open: string[] = [];
for (const dir of closedDirectories())
  for (const file of productTsx(join(ROOT, dir))) {
    const pragma = PRAGMA.exec(readFileSync(file, "utf8"));
    if (!pragma || resolve(dirname(file), pragma[1]) !== CLOSED_RUNTIME) open.push(relative(ROOT, file));
  }

if (open.length > 0) {
  console.error(
    `closed kit: ${open.length} file(s) in a closed directory (tsconfig.closed.json) do not open with the closed runtime's pragma:`,
  );
  for (const file of open)
    console.error(
      `  ${file}: first line \`/** @jsxImportSource ${relative(dirname(join(ROOT, file)), CLOSED_RUNTIME)} */\``,
    );
  process.exit(1);
}
console.log(`closed kit: every product .tsx in ${closedDirectories().length} closed director(ies) carries the pragma`);
