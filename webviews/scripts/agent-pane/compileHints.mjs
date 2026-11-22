// V8's explicit compile hint for the scripts a chat's first frame runs (pane.js and the chunks it
// imports statically). With `//# allFunctionsCalledOnLoad` as a file's first line, V8 compiles
// every function in it eagerly, on the streaming thread while the file loads, instead of lazily on
// the renderer's main thread the first time each is called (https://v8.dev/blog/explicit-compile-hints,
// Chrome 136 and later; the app's Chromium is 157).
//
// It matters for the launch the code cache cannot help: cmux-page's V8 code cache (#44342) is keyed
// by the script's source hash, so the first chat after every update, and every fresh copy's launch,
// compiles pane.js from nothing. Chunks behind dynamic imports (shiki's grammars, KaTeX) are left
// lazy: V8 asks for the hint to be used sparingly, on code that runs at load.
//
// The comment is prepended after esbuild writes, so an external source map gets one empty line in
// front of its mappings (a leading ";") and every frame still maps to the same source line.
import { readFile, writeFile } from "node:fs/promises";

export const COMPILE_HINT = "//# allFunctionsCalledOnLoad";

/** `code` with the hint as its first line; unchanged when it already starts with it. */
export function withCompileHint(code) {
  return code.startsWith(COMPILE_HINT + "\n") ? code : `${COMPILE_HINT}\n${code}`;
}

/** A source map's JSON for code that gained one line at the top: mappings move down one line. */
export function mapWithCompileHint(mapJson) {
  const map = JSON.parse(mapJson);
  map.mappings = ";" + map.mappings;
  return JSON.stringify(map);
}

/** Prepends the hint to each file in `files` (absolute paths), and shifts `<file>.map` when present. */
export async function addCompileHints(files) {
  for (const file of files) {
    const code = await readFile(file, "utf8");
    const hinted = withCompileHint(code);
    if (hinted === code) continue;
    await writeFile(file, hinted);
    const mapFile = file + ".map";
    const map = await readFile(mapFile, "utf8").catch(() => null);
    if (map !== null) await writeFile(mapFile, mapWithCompileHint(map));
  }
}
