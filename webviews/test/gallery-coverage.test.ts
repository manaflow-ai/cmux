// "Every single" stays true: each React component the webviews export and each page the app
// hosts (a PageDescriptor) has a gallery entry, or is named in test/gallery-coverage.allowlist.json.
// The allowlist only shrinks: an allowlisted name that an entry now covers, or that no longer
// exists, fails too. CMUX_GALLERY_UPDATE_ALLOWLIST=1 rewrites the allowlist (after you add entries).
//
// Components: a `.tsx` file's exported PascalCase function or const (`export function Name`,
// `export const Name =`, `export default function Name`). An entry covers `path#Name`, or `path`
// for every export of the file. Pages: the `id:` of each PageDescriptor in the Swift sources,
// covered by `page:<id>`.
//
// On a pull request only its own findings fail (test/support/prScope.ts): ones about a file it
// changes, or a name on an allowlist or covers line it adds or removes. The rest print as warnings.
import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { validateEntries } from "../src/gallery/format";
import { galleryFiles, loadEntries } from "../scripts/gallery/entries";
import { prScope } from "./support/prScope";

const SRC = path.resolve(import.meta.dir, "../src");
const REPO = path.resolve(import.meta.dir, "../..");
const SWIFT = path.join(REPO, "Packages/macOS/CmuxNext/Sources");
const ALLOWLIST = path.join(import.meta.dir, "gallery-coverage.allowlist.json");
/** Not product UI: the gallery itself, dev hosts and prototypes. */
const SKIP_DIRS = new Set(["gallery", "generated", "prototype", "acpmux-preview", "node_modules"]);

function walk(dir: string, keep: (file: string) => boolean): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) out.push(...walk(full, keep));
    } else if (keep(full)) out.push(full);
  }
  return out;
}

const EXPORT = /^export\s+(?:default\s+)?(?:function\s+([A-Z]\w*)|const\s+([A-Z]\w*)\s*[:=])/gm;

/** `path#Name` of every exported component, by file. */
function components(): Map<string, string[]> {
  const byFile = new Map<string, string[]>();
  const files = walk(
    SRC,
    (file) => file.endsWith(".tsx") && !/\.(test|gallery)\.tsx$/.test(file) && !/\/(dev|devHost)\.tsx$/.test(file),
  );
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const names = [...text.matchAll(EXPORT)]
      .map((match) => match[1] ?? match[2]!)
      // Constants in capitals (`COMPOSER_LABELS`) are tables, not components.
      .filter((name) => !/^[A-Z0-9_]+$/.test(name));
    if (names.length) byFile.set(path.relative(SRC, file), [...new Set(names)]);
  }
  return byFile;
}

/** The app's page descriptors: each id, and the repository paths of the Swift files declaring it. */
function pages(): Map<string, string[]> {
  const ids = new Map<string, string[]>();
  for (const file of walk(SWIFT, (candidate) => candidate.endsWith(".swift")))
    for (const match of fs.readFileSync(file, "utf8").matchAll(/PageDescriptor\(\s*id:\s*"([^"]+)"/g))
      ids.set(match[1]!, [...(ids.get(match[1]!) ?? []), path.relative(REPO, file)]);
  return new Map([...ids].sort(([a], [b]) => a.localeCompare(b)));
}

const pageFiles = pages();
const RULES = [
  "webviews/test/gallery-coverage.test.ts",
  "webviews/test/support/prScope.ts",
  "webviews/scripts/gallery/entries.ts",
  // The entry constructors build the covers and ids every coverage test reads.
  "webviews/src/gallery/entry.ts",
];
const LISTS = ["webviews/test/gallery-coverage.allowlist.json", /^webviews\/src\/.*\.gallery\.tsx?$/];
const scope = prScope({ rules: RULES, lists: LISTS });
// validateEntries and its helpers decide only "the entries are valid": a pull request that edits
// them owns every entry problem, not the base branch's coverage gaps.
const validation = prScope({
  rules: [
    ...RULES,
    "webviews/src/gallery/format.ts",
    "webviews/src/gallery/play.ts",
    "webviews/src/experiments/experiment.ts",
    "webviews/src/experiments/tunable.ts",
  ],
  lists: LISTS,
});
/** A component (`file#Name`) or page id: its source files, and the names an allowlist or covers line gives it. */
function place(name: string) {
  if (!name.includes("#")) return { files: pageFiles.get(name) ?? removedPage(name), names: [name, `page:${name}`] };
  const file = name.split("#")[0]!;
  return { files: [`webviews/src/${file}`], names: [name, file] };
}

/** The changed Swift files that declared page `id` on the base branch (a pull request removed or renamed it). */
function removedPage(id: string): string[] {
  const declared = new RegExp(`PageDescriptor\\(\\s*id:\\s*"${id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`);
  return [...scope.changed].filter((file) => {
    if (!file.startsWith(path.relative(REPO, SWIFT) + "/") || !file.endsWith(".swift")) return false;
    try {
      const base = execFileSync("git", ["show", `HEAD^1:${file}`], { cwd: REPO, encoding: "utf8", stdio: "pipe" });
      return declared.test(base);
    } catch {
      return false; // New in the pull request.
    }
  });
}

/** `owners`: a path prefix of allowlisted names, and the lane that owns their entries. */
type Allowlist = { comment?: string; owners?: Record<string, string>; components: string[]; pages: string[] };

describe("gallery coverage", async () => {
  const entries = await loadEntries();
  const byFile = components();
  const allComponents = [...byFile].flatMap(([file, names]) => names.map((name) => `${file}#${name}`)).sort();
  const allPages = [...pageFiles.keys()];
  /** Each entry id's gallery files (more than one for a duplicate id), for the findings about an entry. */
  const entryFiles = new Map<string, string[]>();
  for (const file of galleryFiles()) {
    const id = ((await import(file)) as { default: { id: string } }).default.id;
    entryFiles.set(id, [...(entryFiles.get(id) ?? []), path.relative(REPO, file)]);
  }
  /** A finding `<id>: ...` or `<id>#<variant>: ...`; the longest id it starts with, as ids may hold `:` or `#`. */
  const entryPlace = (problem: string) => {
    const id = [...entryFiles.keys()]
      .filter((candidate) => problem.startsWith(`${candidate}:`) || problem.startsWith(`${candidate}#`))
      .sort((a, b) => b.length - a.length)[0];
    return { files: id === undefined ? [] : entryFiles.get(id)! };
  };
  const covers = entries.flatMap((entry) => entry.covers);
  const coveredComponents = new Set(
    covers
      .filter((cover) => !cover.startsWith("page:") && !cover.startsWith("swift:"))
      .flatMap((cover) =>
        cover.includes("#") ? [cover] : (byFile.get(cover) ?? []).map((name) => `${cover}#${name}`),
      ),
  );
  const coveredPages = new Set(covers.filter((cover) => cover.startsWith("page:")).map((cover) => cover.slice(5)));
  const missing = {
    components: allComponents.filter((name) => !coveredComponents.has(name)),
    pages: allPages.filter((id) => !coveredPages.has(id)),
  };

  const previous = fs.existsSync(ALLOWLIST) ? (JSON.parse(fs.readFileSync(ALLOWLIST, "utf8")) as Allowlist) : undefined;
  if (process.env.CMUX_GALLERY_UPDATE_ALLOWLIST === "1")
    fs.writeFileSync(
      ALLOWLIST,
      `${JSON.stringify(
        {
          comment:
            "Components and pages with no gallery entry yet (test/gallery-coverage.test.ts). Shrink it: add an entry, then rerun with CMUX_GALLERY_UPDATE_ALLOWLIST=1. `owners` names the lane that writes the entries under a path prefix; do not write those yourself.",
          owners: previous?.owners ?? {},
          ...missing,
        },
        null,
        2,
      )}\n`,
    );
  const allowlist = JSON.parse(fs.readFileSync(ALLOWLIST, "utf8")) as Allowlist;

  test("the entries are valid", () => {
    expect(validation.owned(validateEntries(entries), entryPlace, (problem) => problem)).toEqual([]);
  });

  test("every cover names a component or page that exists", () => {
    const unknown = entries.flatMap((entry) =>
      entry.covers
        .map((cover) => ({ entry: entry.id, cover }))
        .filter(({ cover }) => {
          if (cover.startsWith("swift:")) return false;
          if (cover.startsWith("page:")) return !allPages.includes(cover.slice(5));
          const [file, name] = cover.split("#");
          const names = byFile.get(file!);
          return !names || (name !== undefined && !names.includes(name));
        }),
    );
    expect(
      scope.owned(
        unknown,
        ({ entry, cover }) => {
          const own = cover.startsWith("page:")
            ? place(cover.slice(5))
            : place(cover.includes("#") ? cover : `${cover}#`);
          return { files: [...entryPlace(entry).files, ...own.files], names: own.names };
        },
        ({ entry, cover }) => `${entry}: ${cover}`,
      ),
    ).toEqual([]);
  });

  test("every component and page has an entry or an allowlist line", () => {
    const allowed = new Set([...allowlist.components, ...allowlist.pages]);
    const unlisted = [...missing.components, ...missing.pages].filter((name) => !allowed.has(name));
    expect(scope.owned(unlisted, place, (name) => name)).toEqual([]);
  });

  test("the allowlist names only what is still missing", () => {
    const stale = [
      ...allowlist.components.filter((name) => !missing.components.includes(name)),
      ...allowlist.pages.filter((id) => !missing.pages.includes(id)),
    ];
    expect(scope.owned(stale, place, (name) => name)).toEqual([]);
  });

  test("each owner prefix still names allowlisted work", () => {
    const names = [...allowlist.components, ...allowlist.pages];
    const idle = Object.keys(allowlist.owners ?? {}).filter((prefix) => !names.some((name) => name.startsWith(prefix)));
    expect(
      scope.owned(
        idle,
        // The allowlist line that last named the prefix is gone, so a change to the allowlist owns it.
        (prefix) => ({ files: ["webviews/test/gallery-coverage.allowlist.json"], names: [prefix] }),
        (prefix) => prefix,
      ),
    ).toEqual([]);
  });

  test("coverage counts", () => {
    // Printed for the gallery's status line; the assertions above are the gate.
    console.log(
      `gallery: ${entries.length} entries, ${entries.reduce((sum, entry) => sum + Object.keys(entry.variants).length, 0)} variants; ` +
        `components ${allComponents.length - missing.components.length}/${allComponents.length} covered, ` +
        `pages ${allPages.length - missing.pages.length}/${allPages.length} covered`,
    );
    expect(allPages.length).toBeGreaterThanOrEqual(13);
  });
});
