// A page's sections load one file each, and making them lazy changes no other page's chunks.
//
// A section is a module under src/pages/<page>/sections/ that its page loads with import()
// (Settings: lazySections.ts). esbuild gives every module the set of entries that reach it, a
// dynamic import's target included, and writes one chunk per set. It never drops a section from
// that set for code the page has already loaded, so the sections split the page's chunks, and every
// chunk the page shares with other pages, into smaller ones, and a section loaded its own chunk
// plus the small chunks it shared with other sections, one after the other.
//
// Rollup, which builds Chrome's WebUI pages (chrome/browser/resources/tools/optimize_webui.gni),
// drops an entry from a module's dependent entries when everything that imports that entry has
// already loaded the module (rollup src/utils/chunkAssignment.ts, removeUnnecessaryDependentEntries).
// Here a section stands for the page that imports it, which has always loaded first: after the
// esbuild run, the chunks that load with the same pages and lazy entries, counting each section as
// its page, are joined into one file, so the page's chunks are the ones it had with its sections
// built in. The code only the page's sections share is one more file of the page's first load, as
// Chrome's Settings loads shared.rollup.js, what its lazy_load bundle shares with the basic page
// (chrome/browser/resources/settings/BUILD.gn). Each section's file then holds the code only it uses.
//
// The join re-bundles the chunks with esbuild: each joined chunk's exports get new names in the
// joined file, and every file that imports one imports the new name from the joined file instead.
// A joined file is named after its contents (<name>-<hash>.js); a file whose imports alone change
// keeps its name.
import { build } from "esbuild";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const STATIC = "import-statement";
const DYNAMIC = "dynamic-import";
const isScript = (file) => file.endsWith(".js");

/** Every output `file` reaches through imports of `kinds`, `file` first. */
function reach(outputs, file, kinds) {
  const seen = new Set([file]);
  const queue = [file];
  while (queue.length > 0)
    for (const item of outputs[queue.pop()].imports)
      if (!item.external && kinds.has(item.kind) && outputs[item.path] && !seen.has(item.path)) {
        seen.add(item.path);
        queue.push(item.path);
      }
  return seen;
}

/** The outputs that are a section of a page: `{ section output: page }`. Throws for a section another page can load. */
export function sectionOutputs(outputs, { pageEntries, pagesRoot }) {
  const sections = new Map();
  const importers = new Map();
  for (const [file, output] of Object.entries(outputs))
    for (const item of output.imports)
      if (item.kind === DYNAMIC && !item.external)
        importers.set(item.path, [...(importers.get(item.path) ?? []), file]);
  const reachable = new Map(
    [...pageEntries].map(([page, entry]) => [page, reach(outputs, entry, new Set([STATIC, DYNAMIC]))]),
  );
  for (const target of importers.keys()) {
    const source = outputs[target].entryPoint && path.resolve(outputs[target].entryPoint);
    const page = [...pageEntries.keys()].find(
      (name) => source && source.startsWith(path.join(pagesRoot, name, "sections") + path.sep),
    );
    if (!page) continue;
    for (const [other, files] of reachable)
      if (other !== page && importers.get(target).some((file) => files.has(file)))
        throw new Error(`${target} is a section of ${page}, but ${other} can load it`);
    sections.set(target, page);
  }
  return sections;
}

/**
 * The files to join: each group is the chunks that load together once a section counts as its
 * page. A group only a page's sections use is imported by the page's entry (`entry`), so it loads
 * first. Entries are never joined.
 */
export function sectionJoinPlan(outputs, { pageEntries, sections }) {
  const statics = new Set([STATIC]);
  const firstLoads = [...pageEntries].map(([page, entry]) => [`page ${page}`, reach(outputs, entry, statics)]);
  const lazyEntries = new Set(
    Object.values(outputs).flatMap((output) =>
      output.imports.filter((item) => item.kind === DYNAMIC && !item.external).map((item) => item.path),
    ),
  );
  const lazyLoads = [...lazyEntries].map((entry) => [
    sections.has(entry) ? `page ${sections.get(entry)}` : `lazy ${entry}`,
    reach(outputs, entry, statics),
  ]);
  const entries = new Set(pageEntries.values());
  const groups = new Map();
  for (const file of Object.keys(outputs)
    .filter(isScript)
    .sort((x, y) => x.localeCompare(y))) {
    if (lazyEntries.has(file) || entries.has(file)) continue;
    const loads = [...firstLoads, ...lazyLoads].filter(([, files]) => files.has(file)).map(([load]) => load);
    const key = [...new Set(loads)].sort((x, y) => x.localeCompare(y)).join("\n");
    groups.set(key, [...(groups.get(key) ?? []), file]);
  }
  const pageOf = new Map([...pageEntries].map(([page, entry]) => [`page ${page}`, entry]));
  return [...groups].flatMap(([key, files]) => {
    const entry = pageOf.get(key);
    return files.length > 1 || entry ? [{ files, ...(entry ? { entry } : {}) }] : [];
  });
}

/** Export names for a joined file: short, and none of `taken` (or a keyword, for readers that mind). */
function* exportNames(taken) {
  const keywords = new Set(["do", "if", "in"]);
  const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  for (let index = 0; ; index++) {
    let name = "";
    for (let rest = index; ; rest = Math.floor(rest / letters.length) - 1) {
      name = letters[rest % letters.length] + name;
      if (rest < letters.length) break;
    }
    if (!taken.has(name) && !keywords.has(name)) yield name;
  }
}

/** `to` (a path under the build's output) as an import specifier in a file of the folder `fromDir`. */
function specifier(fromDir, to) {
  const relative = path.posix.relative(fromDir, to.split(path.sep).join("/"));
  return relative.startsWith(".") ? relative : `./${relative}`;
}

// esbuild's import and export-from statements: `import{a as b,c}from"x"`, `import"x"`,
// `import*as n from"x"`, `export{a}from"x"`, `export*from"x"`, `import d,{a}from"x"`.
const IMPORT_FROM =
  /\b(?:import|export)\s*(?:([\w$]+)\s*,?\s*)?(\*\s*(?:as\s*[\w$]+)?|\{[^}]*\})?\s*(?:from)?\s*"([^"]+)"/g;

/** The names `code` imports from each specifier: a set, or "*" for all of them. */
export function importedNames(code) {
  const names = new Map();
  for (const [, defaultName, clause, from] of code.matchAll(IMPORT_FROM)) {
    const known = names.get(from) ?? new Set();
    if (known === "*" || clause?.startsWith("*")) {
      names.set(from, "*");
      continue;
    }
    if (defaultName && defaultName !== "default") known.add("default");
    for (const item of (clause ?? "").replace(/[{}]/g, "").split(","))
      if (item.trim()) known.add(item.trim().split(/\s+as\s+|\s+/)[0]);
    names.set(from, known);
  }
  return names;
}

const MEMBER = "cmux-join-member:";
const FINAL = "cmux-join-final:";

/**
 * Joins `plan`'s groups in the esbuild output at `outdir` (its metafile `outputs`, keyed and
 * imported by paths under `outdir`), rewrites every file that imports a joined one, and returns the
 * outputs as they are on disk now.
 */
export async function joinChunks({ outdir, outputs, plan, target }) {
  const joinedInto = new Map(); // a joined output -> its group
  const renamed = new Map(); // a joined output -> { its export -> the joined file's export }
  const final = new Map(); // an output -> the file it is in now
  const groups = plan.map(({ files, entry }) => ({ files, host: files[0], entry }));
  for (const group of groups) for (const file of group.files) joinedInto.set(file, group);
  for (const group of groups) {
    const names = exportNames(new Set(outputs[group.host].exports));
    for (const file of group.files)
      renamed.set(
        file,
        new Map(outputs[file].exports.map((name) => [name, file === group.host ? name : names.next().value])),
      );
  }

  // A group is written after the groups it imports, so it names their files.
  const ordered = [];
  const state = new Map();
  const visit = (group, trail) => {
    if (state.get(group) === "done") return;
    if (state.get(group) === "visiting") throw new Error(`joined chunks import each other: ${trail.join(" -> ")}`);
    state.set(group, "visiting");
    for (const file of group.files)
      for (const item of outputs[file].imports) {
        const next = joinedInto.get(item.path);
        if (!item.external && next && next !== group) visit(next, [...trail, item.path]);
      }
    state.set(group, "done");
    ordered.push(group);
  };
  for (const group of groups) visit(group, [group.host]);
  const loadsFirst = (file) => groups.filter((group) => group.entry === file);
  const touched = Object.keys(outputs).filter(
    (file) =>
      isScript(file) &&
      !joinedInto.has(file) &&
      (loadsFirst(file).length > 0 ||
        outputs[file].imports.some((item) => !item.external && joinedInto.has(item.path))),
  );

  const next = { ...outputs };
  const write = async ({ files, host }, keepName) => {
    const hostDir = path.posix.dirname(host);
    const reexport = (file) => {
      const names = [...(renamed.get(file) ?? outputs[file].exports.map((name) => [name, name]))];
      const from = JSON.stringify(MEMBER + file);
      return names.length === 0
        ? `import ${from};`
        : `export {${names.map(([name, as]) => (name === as ? name : `${name} as ${as}`)).join(",")}} from ${from};`;
    };
    // The joined files' code runs before the host's, as it would have at their first import; the
    // code only the page's sections share loads with the page's entry.
    const entry = [
      ...[...files.filter((file) => file !== host), host].map(reexport),
      ...(keepName ? loadsFirst(host) : []).map((group) => `import ${JSON.stringify(FINAL + final.get(group.host))};`),
    ].join("\n");
    // What these files import from each chunk joined elsewhere: its facade re-exports only that,
    // since esbuild keeps every name a facade re-exports from an external file.
    const wanted = new Map();
    for (const file of files) {
      const code = fs.readFileSync(path.join(outdir, file), "utf8");
      for (const [from, names] of importedNames(code)) {
        if (/^[a-z][a-z0-9+.-]*:/i.test(from)) continue;
        const target = path.posix.join(path.posix.dirname(file), from);
        if (!joinedInto.has(target) || files.includes(target)) continue;
        const known = wanted.get(target) ?? new Set();
        wanted.set(target, names === "*" || known === "*" ? "*" : new Set([...known, ...names]));
      }
    }
    const result = await build({
      entryPoints: [`${MEMBER}entry`],
      bundle: true,
      format: "esm",
      platform: "browser",
      target,
      minify: true,
      legalComments: "none",
      logLevel: "warning",
      write: false,
      metafile: true,
      outdir: path.join(outdir, hostDir),
      plugins: [
        {
          name: "cmux-join-chunks",
          setup(bundle) {
            bundle.onResolve({ filter: /.*/ }, (args) => {
              if (args.path === `${MEMBER}entry`) return { path: "entry", namespace: "cmux-join" };
              if (args.path.startsWith(MEMBER)) return { path: path.join(outdir, args.path.slice(MEMBER.length)) };
              if (args.path.startsWith(FINAL))
                return { path: specifier(hostDir, args.path.slice(FINAL.length)), external: true };
              if (/^[a-z][a-z0-9+.-]*:/i.test(args.path)) return { path: args.path, external: true };
              const file = path.relative(outdir, path.resolve(args.resolveDir, args.path)).split(path.sep).join("/");
              if (files.includes(file)) return { path: path.join(outdir, file) };
              const into = joinedInto.get(file);
              if (into && args.kind === DYNAMIC)
                throw new Error(`${file} is joined, but ${args.importer} imports it with import()`);
              if (into) return { path: file, namespace: "cmux-join-facade" };
              return { path: specifier(hostDir, final.get(file) ?? file), external: true };
            });
            bundle.onLoad({ filter: /.*/, namespace: "cmux-join" }, () => ({
              contents: entry,
              loader: "js",
              resolveDir: outdir,
            }));
            // An import of a chunk joined elsewhere: its exports under their names in the joined file.
            bundle.onLoad({ filter: /.*/, namespace: "cmux-join-facade" }, (args) => {
              const from = JSON.stringify(FINAL + final.get(args.path));
              const exported = renamed.get(args.path);
              const used = wanted.get(args.path) ?? new Set();
              const names = used === "*" ? [...exported.keys()] : [...used];
              const missing = names.filter((name) => !exported.has(name));
              if (missing.length) throw new Error(`${args.path} exports no ${missing.join(", ")}`);
              const contents = names.length
                ? `export {${names.map((name) => (exported.get(name) === name ? name : `${exported.get(name)} as ${name}`)).join(",")}} from ${from};`
                : `import ${from};`;
              return { contents, loader: "js", resolveDir: outdir };
            });
          },
        },
      ],
    });
    const code = result.outputFiles[0].contents;
    const [built] = Object.values(result.metafile.outputs);
    const stem = path.posix.basename(host).replace(/-[^-]*\.js$/, "");
    const hash = createHash("sha256").update(code).digest("hex").slice(0, 8).toUpperCase();
    const file = keepName ? host : path.posix.join(hostDir, `${stem}-${hash}.js`);
    for (const member of files) {
      fs.rmSync(path.join(outdir, member));
      delete next[member];
      final.set(member, file);
    }
    fs.writeFileSync(path.join(outdir, file), code);
    next[file] = {
      ...outputs[host],
      bytes: code.byteLength,
      exports: built.exports,
      imports: built.imports.map((item) =>
        item.external && item.path.startsWith(".")
          ? { ...item, path: path.posix.join(hostDir, item.path), external: false }
          : item,
      ),
    };
  };
  for (const group of ordered) await write(group, false);
  for (const file of touched) await write({ files: [file], host: file }, true);
  return next;
}

/**
 * The esbuild `outputs` at `outdir` with each page's sections (`pageEntries`: page -> its entry's
 * output, `pagesRoot`: the pages' sources) loading one file each (the header).
 */
export async function joinSectionChunks({ outdir, outputs, pageEntries, pagesRoot, target }) {
  const sections = sectionOutputs(outputs, { pageEntries, pagesRoot });
  if (sections.size === 0) return outputs;
  const plan = sectionJoinPlan(outputs, { pageEntries, sections });
  return joinChunks({ outdir, outputs, plan, target });
}
