// The agent pane's site table (chunks/frame-sites.js): for each script the bundle writes, where each
// source file's code starts, so `cmux app chat perf` can name the file behind a release build's stack
// position (src/agent-session/acpmux/frameOwners.ts). bundle.mjs --frame-sites builds the pane with
// external source maps, calls `writeFrameSites`, and deletes the maps: they never ship. The table
// holds only paths under webviews/, package names and `build:` paths (code the build itself wrote,
// named from the output's parent, so no temp directory reaches it and a rebuild writes the same
// bytes), and the page imports it only once a capture has ended.
import { readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const DIGIT = new Map(B64.split("").map((char, index) => [char, index]));

/** One mapping segment's base64 VLQ values. */
function decodeSegment(text) {
  const values = [];
  let shift = 0;
  let value = 0;
  for (const char of text) {
    const digit = DIGIT.get(char);
    if (digit === undefined) throw new Error(`frame sites: bad source map character ${char}`);
    value += (digit & 31) << shift;
    if (digit & 32) shift += 5;
    else {
      values.push(value & 1 ? -(value >>> 1) : value >>> 1);
      shift = 0;
      value = 0;
    }
  }
  return values;
}

/**
 * A source map source as the table names it: a path under webviews/, `node_modules/<package>`, or
 * `build:<path under buildRoot>` for a file outside webviews/ (a chunk the build wrote to its temp
 * directory), so the table's bytes do not depend on where the build ran.
 */
export function siteSource(source, mapDir, webviewsRoot, buildRoot) {
  if (/^[a-z][\w+.-]*:/i.test(source) && !source.startsWith("file:")) return source;
  const absolute = path.resolve(mapDir, source.replace(/^file:\/\//, ""));
  const relative = path.relative(webviewsRoot, absolute).split(path.sep).join("/");
  const packaged = /(?:^|\/)node_modules\/((?:@[^/]+\/)?[^/]+)(?!.*\/node_modules\/)/.exec(relative);
  if (packaged) return `node_modules/${packaged[1]}`;
  if (buildRoot && (relative === ".." || relative.startsWith("../"))) {
    return `build:${path.relative(buildRoot, absolute).split(path.sep).join("/")}`;
  }
  return relative;
}

/**
 * Where each source's code starts in one generated script, as [line, column, source] triples
 * (0-based, in order), from its source map; consecutive code from one source is one entry.
 */
export function boundaries(map, toSource, sources) {
  const index = new Map(sources.map((name, at) => [name, at]));
  const named = map.sources.map((source) => {
    const name = toSource(source);
    if (!index.has(name)) {
      index.set(name, sources.length);
      sources.push(name);
    }
    return index.get(name);
  });
  const marks = [];
  let source = 0;
  let last = -1;
  map.mappings.split(";").forEach((line, lineIndex) => {
    let column = 0;
    for (const segment of line.split(",")) {
      if (!segment) continue;
      const values = decodeSegment(segment);
      column += values[0];
      if (values.length < 4) continue;
      source += values[1];
      const at = named[source];
      if (at === last) continue;
      last = at;
      marks.push(lineIndex, column, at);
    }
  });
  return marks;
}

/**
 * Reads each `<script>.map` beside the scripts in `outputs` (paths relative to `outdir`), writes the
 * table to `file` as an ES module, and deletes the maps.
 */
export async function writeFrameSites({ outdir, outputs, file, webviewsRoot }) {
  const sources = [];
  const files = {};
  for (const output of outputs) {
    const script = path.resolve(outdir, output);
    const mapFile = `${script}.map`;
    // A stylesheet's map (a chunk's imported CSS) is only deleted.
    if (!script.endsWith(".js")) {
      await rm(mapFile, { force: true });
      continue;
    }
    let map;
    try {
      map = JSON.parse(await readFile(mapFile, "utf8"));
    } catch {
      continue;
    }
    const mapDir = path.dirname(mapFile);
    const key = path.relative(outdir, script).split(path.sep).join("/");
    files[key] = boundaries(
      map,
      (source) => siteSource(source, mapDir, webviewsRoot, path.dirname(path.resolve(outdir))),
      sources,
    );
    await rm(mapFile, { force: true });
  }
  await writeFile(file, `export default ${JSON.stringify({ sources, files })};\n`);
  return { sources: sources.length, files: Object.keys(files).length };
}
