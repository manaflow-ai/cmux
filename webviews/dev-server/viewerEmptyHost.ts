// Pure pieces of the dev host for the viewer empty states (plugins.ts), split out so
// test/viewer-empty-dev-server.test.ts can cover them: the recent repositories and markdown files
// (a small JSON file in the slot's state folder) and the fallback picker's folder listing, which
// lists only inside the allowed roots (the user's home in dev). Dev server only; nothing ships.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export type RecentKind = "diff" | "markdown";

export interface DevRecent {
  path: string;
  openedAt: number;
  source?: string;
}

export const RECENTS_KEPT = 20;
export const RECENTS_SHOWN = 8;
export const LISTING_LIMIT = 2000;

/** The state folder of this server: the slot's (`CMUX_WEBVIEWS_DEV_STATE_DIR`), else one per port. */
export function devStateDirectory(port: number, env: NodeJS.ProcessEnv = process.env): string {
  return env.CMUX_WEBVIEWS_DEV_STATE_DIR || path.join(os.tmpdir(), `cmux-webviews-dev-${port}`);
}

/** The recents file: `{diff: DevRecent[], markdown: DevRecent[]}`, newest first. */
export function devRecents(directory: string, now: () => number = Date.now) {
  const file = path.join(directory, "viewer-recents.json");
  const read = (): Record<RecentKind, DevRecent[]> => {
    try {
      const value = JSON.parse(fs.readFileSync(file, "utf8"));
      return {
        diff: Array.isArray(value?.diff) ? value.diff : [],
        markdown: Array.isArray(value?.markdown) ? value.markdown : [],
      };
    } catch {
      return { diff: [], markdown: [] };
    }
  };
  return {
    file,
    /** Moves `entry` to the front of `kind`, keeping the last RECENTS_KEPT. */
    record(kind: RecentKind, entry: { path: string; source?: string }): void {
      const all = read();
      const previous = all[kind].find((item) => item.path === entry.path);
      const next: DevRecent = { path: entry.path, openedAt: now() };
      const source = entry.source ?? previous?.source;
      if (source) next.source = source;
      all[kind] = [next, ...all[kind].filter((item) => item.path !== entry.path)].slice(0, RECENTS_KEPT);
      fs.mkdirSync(directory, { recursive: true });
      fs.writeFileSync(file, `${JSON.stringify(all, null, 2)}\n`);
    },
    /** The last `limit` items of `kind` that still exist. */
    list(kind: RecentKind, limit = RECENTS_SHOWN): DevRecent[] {
      return read()
        [kind].filter((item) => typeof item?.path === "string" && typeof item.openedAt === "number")
        .filter((item) => fs.existsSync(item.path))
        .slice(0, limit);
    },
  };
}

/** A recent repository with its current branch (`git branch --show-current`), when it has one. */
export function withBranch(item: DevRecent): DevRecent & { branch?: string } {
  try {
    const branch = execFileSync("git", ["-C", item.path, "branch", "--show-current"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 2000,
    }).trim();
    return branch ? { ...item, branch } : item;
  } catch {
    return item;
  }
}

export class ListingRefused extends Error {}

/// Home folders macOS guards with a privacy prompt (TCC). The listing never looks inside them on
/// its own (the git check), so listing home does not prompt; entering one is the user's choice.
const PROTECTED_HOME_FOLDERS = new Set(["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"]);

/** Whether `real` is `root` or below it. */
function inside(real: string, root: string): boolean {
  return real === root || real.startsWith(root.endsWith("/") ? root : `${root}/`);
}

/** The real path of `requested` when it is inside one of `roots`, else undefined. */
export function allowedPath(requested: string, roots: readonly string[]): string | undefined {
  let real: string;
  try {
    real = fs.realpathSync(requested);
  } catch {
    return undefined;
  }
  return roots.some((root) => inside(real, root)) ? real : undefined;
}

function isMarkdownName(name: string): boolean {
  return /\.(md|markdown|mdx|mdown|mkd)$/i.test(name);
}

/**
 * One folder level for the fallback picker (`cmux.picker.list`): folders (marked when they are a
 * git repository's top level) and, in file mode, markdown files. Hidden entries only when
 * `hidden`. `requested` null or `~` is home. A folder outside `roots` is refused.
 */
export function listPickerDirectory(
  requested: string | null,
  options: { roots: readonly string[]; home: string; mode: "folder" | "file"; hidden: boolean },
) {
  const raw = requested == null || requested === "" || requested === "~" ? options.home : requested;
  const expanded = raw.startsWith("~/") ? path.join(options.home, raw.slice(2)) : raw;
  const roots = options.roots.map((root) => fs.realpathSync(root));
  const directory = allowedPath(path.resolve(expanded), roots);
  if (!directory || !fs.statSync(directory).isDirectory()) throw new ListingRefused(`not listable: ${raw}`);
  const home = fs.realpathSync(options.home);
  const entries: Array<{ name: string; path: string; kind: "dir" | "file"; git?: boolean }> = [];
  for (const dirent of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entries.length >= LISTING_LIMIT) break;
    if (!options.hidden && dirent.name.startsWith(".")) continue;
    const full = path.join(directory, dirent.name);
    let isDirectory = dirent.isDirectory();
    let isFile = dirent.isFile();
    if (dirent.isSymbolicLink()) {
      try {
        const stat = fs.statSync(full);
        isDirectory = stat.isDirectory();
        isFile = stat.isFile();
      } catch {
        continue;
      }
    }
    if (isDirectory) {
      if (directory === home && PROTECTED_HOME_FOLDERS.has(dirent.name)) {
        entries.push({ name: dirent.name, path: full, kind: "dir" });
        continue;
      }
      entries.push({
        name: dirent.name,
        path: full,
        kind: "dir",
        git: fs.existsSync(path.join(full, ".git")) || undefined,
      });
    } else if (isFile && options.mode === "file" && isMarkdownName(dirent.name)) {
      entries.push({ name: dirent.name, path: full, kind: "file" });
    }
  }
  entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
  const atRoot = roots.includes(directory);
  return {
    path: directory,
    parent: atRoot ? null : path.dirname(directory),
    home,
    entries,
  };
}

/** The git top level of `folder`, or undefined when it is not inside a repository. */
export function gitTopLevel(folder: string): string | undefined {
  try {
    const top = execFileSync("git", ["-C", folder, "rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 4000,
    }).trim();
    return top ? fs.realpathSync(top) : undefined;
  } catch {
    return undefined;
  }
}

/** The base a branch diff of `repo` uses when the user picked none: origin's HEAD, main, master. */
export function defaultBranchBase(repo: string): string {
  const git = (...args: string[]) =>
    execFileSync("git", ["-C", repo, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 4000,
    }).trim();
  try {
    const remote = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD");
    if (remote) return remote;
  } catch {}
  for (const name of ["main", "master"]) {
    try {
      git("rev-parse", "--verify", "--quiet", `refs/heads/${name}`);
      return name;
    } catch {}
  }
  return "HEAD";
}

/** The `/__cmux-diff/config` query of a session source the empty state chose. */
export function sourceQuery(source: unknown, repo: string, base: () => string): URLSearchParams {
  const value = (source ?? {}) as { kind?: unknown; baseRef?: unknown };
  const query = new URLSearchParams({ repo });
  if (value.kind === "staged" || value.kind === "unstaged") {
    query.set("source", value.kind);
    return query;
  }
  query.set("source", "branch");
  query.set("base", typeof value.baseRef === "string" && value.baseRef !== "" ? value.baseRef : base());
  return query;
}

/** The empty-state source kind a session source stands for, for the recents. */
export function sourceKind(source: unknown): string {
  const value = (source ?? {}) as { kind?: unknown; baseRef?: unknown };
  if (value.kind === "staged" || value.kind === "unstaged") return value.kind;
  return value.baseRef === "HEAD" ? "uncommitted" : "branch";
}
