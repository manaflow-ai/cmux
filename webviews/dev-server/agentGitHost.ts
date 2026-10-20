// The agent pane's repository reads in the browser dev slot (scripts/agent-pane/dev-slot.sh):
// `git.status`, `git.diff`, `git.checkpoint.diff` and `file.search`, which the cmux session host
// answers inside the app (cmux-tui git_ops: diff.rs, files.rs, git_ops.rs `status`). The dev page
// (src/dev-host/host.ts) posts them to /__dev-host/read, and this answers them in the same wire
// shapes from the folder the slot was started in.
//
// Read only: every git run goes through `readOnlyGit`, which refuses any subcommand outside a
// fixed read list, and every request's folder must be the slot's folder or inside it (the `cwd`
// file in CMUX_WEBVIEWS_DEV_STATE_DIR, which dev-slot.sh writes). Without a slot, every read is
// refused. Dev server only; nothing here ships.
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fuzzy } from "../src/agent-session/acpmux/mockFiles";
import { OUTSIDE_REPOSITORY } from "../src/agent-session/acpmux/fileSearchModel";
import { allowedPath } from "./viewerEmptyHost";

export const AGENT_READ_METHODS = [
  "git.status",
  "git.diff",
  "git.checkpoint.diff",
  "file.search",
  "file.list",
] as const;
export type AgentReadMethod = (typeof AGENT_READ_METHODS)[number];

/// The error a refused or failed read answers with, as the session host words it.
export class AgentReadError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

const SCOPES = new Set(["uncommitted", "unstaged", "staged", "committed", "branch"]);
// As cmux-tui's git_ops/diff.rs and files.rs.
const MAX_UNTRACKED_FILES = 200;
const MAX_UNTRACKED_FILE_BYTES = 2 * 1024 * 1024;
const MAX_REPLY_PATCH_BYTES = 8 * 1024 * 1024;
const DEFAULT_PATCH_BYTES = 262_144;
const DEFAULT_MAX_FILES = 500;
const MAX_CONTEXT_LINES = 1_000_000;
const SEARCH_DEFAULT_LIMIT = 50;
const SEARCH_MAX_LIMIT = 200;
const MAX_GIT_OUTPUT = 64 * 1024 * 1024;

/** The slot's folder (real path), from `$CMUX_WEBVIEWS_DEV_STATE_DIR/cwd`, or undefined outside a slot. */
export function slotFolder(env: NodeJS.ProcessEnv = process.env): string | undefined {
  const state = env.CMUX_WEBVIEWS_DEV_STATE_DIR;
  if (!state) return undefined;
  try {
    const recorded = fs.readFileSync(path.join(state, "cwd"), "utf8").trim();
    return recorded ? fs.realpathSync(recorded) : undefined;
  } catch {
    return undefined;
  }
}

/// Subcommands a read may run. `symbolic-ref` and `config` also write with more arguments, so
/// `readOnlyGit` checks their form too.
const READ_SUBCOMMANDS = new Set(["status", "diff", "rev-parse", "merge-base", "ls-files", "symbolic-ref", "config"]);

/// Long options that write a file or run a program. git takes any unambiguous prefix of a long
/// option, so a prefix of one of these is refused too.
const DENIED_OPTIONS = ["output", "ext-diff", "textconv", "exec", "upload-pack", "open-files-in-pager"];

/** Whether `args` is a git run on the read list (never a write). */
export function isReadOnlyGit(args: readonly string[]): boolean {
  const [subcommand, ...all] = args;
  if (!subcommand || !READ_SUBCOMMANDS.has(subcommand)) return false;
  // Past `--` every token is a path.
  const end = all.indexOf("--");
  const rest = end < 0 ? all : all.slice(0, end);
  const denied = (arg: string) => {
    if (!arg.startsWith("--")) return false;
    const name = arg.slice(2).split("=")[0]!;
    return name.length > 0 && DENIED_OPTIONS.some((option) => option.startsWith(name));
  };
  if (rest.some(denied)) return false;
  if (subcommand === "symbolic-ref")
    return (
      rest.filter((arg) => !arg.startsWith("-")).length === 1 && !rest.some((arg) => /^(-d|--delete|-m)$/.test(arg))
    );
  if (subcommand === "config") return rest[0] === "--get" && rest.length === 2;
  return true;
}

type GitRun = { stdout: string; code: number };

type Setting = readonly [key: string, value: string];

/// The environment git runs with, as cmux-git's run.rs: none of the dev's GIT_* variables (a
/// GIT_DIR would redirect the read), no prompt, no optional index write, literal pathspecs, no
/// lazy fetch of a partial clone's missing objects and no transport at all. `settings` go in as
/// GIT_CONFIG_KEY_n/VALUE_n, which outrank the repository's config and, unlike `-c key=value`,
/// keep a key containing "=" whole.
function gitEnvironment(settings: readonly Setting[]): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [name, value] of Object.entries(process.env)) if (!name.startsWith("GIT_")) env[name] = value;
  settings.forEach(([key, value], index) => {
    env[`GIT_CONFIG_KEY_${index}`] = key;
    env[`GIT_CONFIG_VALUE_${index}`] = value;
  });
  return {
    ...env,
    GIT_CONFIG_COUNT: String(settings.length),
    GIT_TERMINAL_PROMPT: "0",
    GIT_OPTIONAL_LOCKS: "0",
    GIT_PAGER: "cat",
    GIT_LITERAL_PATHSPECS: "1",
    GIT_NO_LAZY_FETCH: "1",
    // A list naming no protocol: every transport is refused, whatever the config allows.
    GIT_ALLOW_PROTOCOL: "cmux-dev-none",
    LC_ALL: "C",
  };
}

/// Settings every run passes, as run.rs: the repository's fsmonitor command never runs, a
/// submodule's change is a one-line summary (never a child `git diff` with its own drivers), and
/// no transport is allowed. The orderfile and global attributes file are never read, since a
/// repository naming /dev/zero for either has git read until memory runs out. No hook runs: a
/// working-tree diff rewrites a stale index despite GIT_OPTIONAL_LOCKS, and every index write
/// runs post-index-change from .git/hooks or core.hooksPath.
const BASE_SETTINGS: readonly Setting[] = [
  ["core.fsmonitor", "false"],
  ["core.hooksPath", "/dev/null"],
  ["diff.orderFile", "/dev/null"],
  ["core.attributesFile", "/dev/null"],
  ["core.quotePath", "false"],
  ["log.showSignature", "false"],
  ["diff.submodule", "short"],
  ["protocol.allow", "never"],
];

function runGit(cwd: string, args: readonly string[], settings: readonly Setting[] = BASE_SETTINGS): Promise<GitRun> {
  return new Promise((resolve, reject) => {
    execFile(
      "git",
      ["--no-optional-locks", "-C", cwd, ...args],
      { encoding: "utf8", maxBuffer: MAX_GIT_OUTPUT, timeout: 15_000, env: gitEnvironment(settings) },
      (error, stdout, stderr) => {
        if (!error) return resolve({ stdout, code: 0 });
        const code = (error as { code?: unknown }).code;
        if (typeof code === "number") return resolve({ stdout, code });
        reject(new Error(String(stderr || error.message)));
      },
    );
  });
}

/// A filter driver runs a program on file contents, and reading the working tree would run it.
/// Every driver the repository's config names is blanked (cmux-git repository.rs
/// filter_overrides): an empty command is no filter, and none is required.
export async function filterOverrides(cwd: string): Promise<Setting[]> {
  const pattern = String.raw`^filter\..*\.(clean|smudge|process|required)$`;
  const listed = await runGit(cwd, ["config", "--null", "--name-only", "--get-regexp", pattern]);
  // `--get-regexp` exits 1 when nothing matches.
  if (listed.code === 1 && !listed.stdout) return [];
  if (listed.code !== 0) throw new AgentReadError("operation.failed", "could not read the repository's filter drivers");
  const drivers = new Set<string>();
  for (const key of listed.stdout.split("\0")) {
    const match = key.match(/^filter\.(.*)\.[^.]+$/s);
    if (match) drivers.add(match[1]!);
  }
  return [...drivers].flatMap((driver): Setting[] => [
    [`filter.${driver}.clean`, ""],
    [`filter.${driver}.smudge`, ""],
    [`filter.${driver}.process`, ""],
    [`filter.${driver}.required`, "false"],
  ]);
}

/** Runs a read-only git command in `cwd`; refuses anything off the read list. */
export async function readOnlyGit(cwd: string, args: readonly string[]): Promise<GitRun> {
  if (!isReadOnlyGit(args)) throw new Error(`refused git ${args[0] ?? ""}: not a read`);
  return runGit(cwd, args, [...BASE_SETTINGS, ...(await filterOverrides(cwd))]);
}

async function gitText(cwd: string, args: string[]): Promise<string | undefined> {
  const run = await readOnlyGit(cwd, args);
  return run.code === 0 ? run.stdout.trim() : undefined;
}

const commit = (cwd: string, ref: string) => gitText(cwd, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);

/** The request's folder: the slot's folder or inside it, else refused. */
export function confinedFolder(requested: unknown, slot: string | undefined): string {
  if (!slot) throw new AgentReadError("native.unsupported", "no dev slot: start one with dev-slot.sh up N");
  const folder = typeof requested === "string" && requested ? requested : slot;
  const real = allowedPath(folder, [slot]);
  if (!real) throw new AgentReadError("native.unsupported", `${folder} is outside the dev slot's folder ${slot}`);
  return real;
}

/** The repository's top level, or the session host's `not_a_repository` failure. */
async function topLevel(cwd: string, operation: string): Promise<string> {
  const top = await gitText(cwd, ["rev-parse", "--show-toplevel"]);
  if (top) return top;
  const reason = `${cwd} is not in a git repository`;
  throw new AgentReadError("operation.failed", reason, {
    operation,
    reason,
    extra: { code: OUTSIDE_REPOSITORY },
  });
}

/** The base a branch diff compares with: the branch's recorded cmuxBase, else origin's default. */
async function baseBranch(root: string): Promise<{ ref: string; short: string } | undefined> {
  const branch = await gitText(root, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
  if (branch) {
    const recorded = await gitText(root, ["config", "--get", `branch.${branch}.cmuxBase`]);
    if (recorded && !recorded.startsWith("-")) {
      for (const ref of [`refs/heads/${recorded}`, `refs/remotes/${recorded}`, recorded])
        if (await commit(root, ref)) return { ref, short: recorded };
    }
  }
  const origin = await gitText(root, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]);
  if (origin?.startsWith("refs/remotes/") && (await commit(root, origin)))
    return { ref: origin, short: origin.slice("refs/remotes/".length) };
  for (const [ref, short] of [
    ["refs/remotes/origin/main", "origin/main"],
    ["refs/remotes/origin/master", "origin/master"],
    ["refs/heads/main", "main"],
    ["refs/heads/master", "master"],
  ] as const)
    if (await commit(root, ref)) return { ref, short };
  return undefined;
}

/** `git.status`: GitStatusResult. */
export async function gitStatus(cwd: string) {
  const root = await topLevel(cwd, "git.status");
  const run = await readOnlyGit(root, [
    "status",
    "--porcelain=v2",
    "--branch",
    "-z",
    "--untracked-files=no",
    "--ignore-submodules=all",
  ]);
  const value: Record<string, unknown> = { root, detached: true, ahead: 0, behind: 0 };
  for (const token of run.stdout.split("\0")) {
    const header = token.match(/^# branch\.(\w+) (.*)$/);
    if (!header) continue;
    const [, key, text] = header;
    if (key === "oid" && text !== "(initial)") value.head = text;
    if (key === "head" && text !== "(detached)") {
      value.branch = text;
      value.detached = false;
    }
    if (key === "upstream") value.upstream = text;
    if (key === "ab")
      for (const count of text!.split(" ")) {
        if (count.startsWith("+")) value.ahead = Number(count.slice(1)) || 0;
        if (count.startsWith("-")) value.behind = Number(count.slice(1)) || 0;
      }
  }
  const base = await baseBranch(root);
  if (base) value.base = base.short;
  return value;
}

type Comparison = { revisions?: string[]; cached: boolean; untracked: boolean; head?: string; base?: string };
type ChangedFile = {
  path: string;
  previous_path?: string;
  status: "added" | "modified" | "deleted" | "renamed" | "untracked";
  additions: number;
  deletions: number;
  binary?: boolean;
  patch?: string;
  patch_truncated?: boolean;
};

const EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/** What a scope compares, as cmux_git::diff::comparison. */
async function comparison(root: string, scope: string): Promise<Comparison> {
  if (!SCOPES.has(scope))
    throw new AgentReadError("validation.invalid", `unknown scope ${JSON.stringify(scope)}`, { field: "scope" });
  const head = await commit(root, "HEAD");
  const compare = (revisions: string[], cached: boolean, untracked: boolean, base?: string): Comparison => ({
    revisions,
    cached,
    untracked,
    head,
    base,
  });
  switch (scope) {
    case "uncommitted":
      return compare([head ?? EMPTY_TREE], false, true);
    case "unstaged":
      return compare([], false, true);
    case "staged":
      return compare([], true, false);
    case "committed": {
      if (!head) return { cached: false, untracked: false };
      const parent = await commit(root, `${head}^1`);
      return compare([parent ?? EMPTY_TREE, head], false, false, parent);
    }
    default: {
      const base = await baseBranch(root);
      if (!base)
        throw new AgentReadError(
          "operation.failed",
          "no base branch: origin's default branch, main and master are all missing",
          {
            operation: "git.diff",
            extra: { code: "no_base_branch" },
          },
        );
      const mergeBase = await gitText(root, ["merge-base", "HEAD", base.ref]);
      if (!mergeBase)
        throw new AgentReadError("operation.failed", `HEAD and ${base.short} have no common commit`, {
          operation: "git.diff",
          extra: { code: "no_merge_base", base: base.short },
        });
      return compare([mergeBase], false, true, mergeBase);
    }
  }
}

function diffArgs(compared: Comparison, mode: string[], paths: string[]): string[] {
  return [
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-relative",
    "--ignore-submodules=dirty",
    "--submodule=short",
    "-M",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    ...mode,
    ...(compared.cached ? ["--cached"] : []),
    ...(compared.revisions ?? []),
    "--",
    ...paths,
  ];
}

async function gitOutput(root: string, args: string[]): Promise<string> {
  const run = await readOnlyGit(root, args);
  if (run.code !== 0) throw new AgentReadError("operation.failed", `git ${args[0]} failed (${run.code})`);
  return run.stdout;
}

/// A copy is a new file; its source is unchanged.
const STATUS_CODES: Record<string, ChangedFile["status"]> = { A: "added", D: "deleted", R: "renamed", C: "added" };

function nameStatus(output: string): ChangedFile[] {
  const tokens = output.split("\0");
  const files: ChangedFile[] = [];
  const seen = new Set<string>();
  for (let index = 0; index < tokens.length;) {
    const code = tokens[index++];
    if (!code) continue;
    const paired = code[0] === "R" || code[0] === "C";
    const first = tokens[index++];
    const second = paired ? tokens[index++] : undefined;
    if (first === undefined || (paired && second === undefined)) break;
    const file: ChangedFile = {
      path: paired ? second! : first,
      status: STATUS_CODES[code[0]!] ?? "modified",
      additions: 0,
      deletions: 0,
    };
    if (code[0] === "R") file.previous_path = first;
    // An unmerged path is listed once per side; keep its first entry.
    if (!seen.has(file.path)) files.push(file);
    seen.add(file.path);
  }
  return files;
}

function numstat(output: string): Map<string, { additions: number; deletions: number } | undefined> {
  const tokens = output.split("\0");
  const counts = new Map<string, { additions: number; deletions: number } | undefined>();
  for (let index = 0; index < tokens.length;) {
    const token = tokens[index++];
    if (!token) continue;
    const [additions, deletions, ...rest] = token.split("\t");
    let file = rest.join("\t");
    // A rename leaves the path empty and names old, then new, next.
    if (!file) {
      index++;
      file = tokens[index++] ?? "";
    }
    counts.set(file, additions === "-" ? undefined : { additions: Number(additions), deletions: Number(deletions) });
  }
  return counts;
}

/// A `--- a/x` / `+++ b/x` path, unquoted; undefined for /dev/null.
function headerPath(line: string, marker: string, prefix: string): string | undefined {
  if (!line.startsWith(marker)) return undefined;
  let rest = line.slice(marker.length).replace(/\r?\n$/, "");
  if (rest.startsWith('"')) {
    try {
      // git C-quotes octal bytes; decode them as UTF-8.
      const bytes: number[] = [];
      const body = rest.slice(1, -1);
      for (let index = 0; index < body.length; index++) {
        const char = body[index]!;
        if (char !== "\\") {
          bytes.push(...Buffer.from(char));
          continue;
        }
        const next = body[++index]!;
        if (/[0-7]/.test(next)) {
          bytes.push(parseInt(body.slice(index, index + 3), 8));
          index += 2;
        } else
          bytes.push(
            ({ n: 10, t: 9, r: 13, '"': 34, "\\": 92, a: 7, b: 8, f: 12, v: 11 } as Record<string, number>)[next] ??
              next.charCodeAt(0),
          );
      }
      rest = Buffer.from(bytes).toString("utf8");
    } catch {
      return undefined;
    }
  }
  return rest.startsWith(prefix) ? rest.slice(prefix.length) : undefined;
}

/** `git diff --patch` output as each file's patch from its first `@@`, keyed by (new) path. */
export function splitPatches(output: string): Map<string, string> {
  const patches = new Map<string, string>();
  const lines = output.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  let section: string[] = [];
  const flush = () => {
    const first = section.findIndex((line) => line.startsWith("@@"));
    if (first < 0) return;
    const header = section.slice(0, first);
    const name =
      header.map((line) => headerPath(line, "+++ ", "b/")).find(Boolean) ??
      header.map((line) => headerPath(line, "--- ", "a/")).find(Boolean);
    if (name) patches.set(name, section.slice(first).join(""));
  };
  for (const line of lines) {
    if ((line.startsWith("diff --git ") || line.startsWith("diff --cc ")) && section.length) {
      flush();
      section = [];
    }
    section.push(line);
  }
  if (section.length) flush();
  return patches;
}

/** An untracked file counts its lines as additions; a binary, special or large one counts none. */
function untrackedFile(root: string, file: string): ChangedFile {
  const changed: ChangedFile = { path: file, status: "untracked", additions: 0, deletions: 0 };
  let bytes: Buffer;
  try {
    const stat = fs.lstatSync(path.join(root, file));
    if (!stat.isFile() || stat.size > MAX_UNTRACKED_FILE_BYTES) return changed;
    bytes = fs.readFileSync(path.join(root, file));
  } catch {
    return changed;
  }
  if (bytes.subarray(0, 8000).includes(0)) return { ...changed, binary: true };
  let newlines = 0;
  for (const byte of bytes) if (byte === 10) newlines++;
  changed.additions = newlines + (bytes.length && bytes[bytes.length - 1] !== 10 ? 1 : 0);
  return changed;
}

function pathspecs(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((entry) => {
    const raw = String(entry);
    if (!raw || raw.startsWith("-") || path.isAbsolute(raw) || raw.split(/[\\/]/).some((part) => part === ".."))
      throw new AgentReadError(
        "validation.invalid",
        `${JSON.stringify(raw)} must be relative to the repository root and stay inside it`,
        { field: "paths" },
      );
    // Literal (GIT_LITERAL_PATHSPECS): never pathspec magic; and never read as an option.
    return raw;
  });
}

const positive = (value: unknown, fallback: number) =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : fallback;

/** The changed files a comparison finds, with counts and, on request, bounded patches. */
async function report(root: string, compared: Comparison, params: Record<string, unknown>) {
  const paths = pathspecs(params.paths);
  const maxPatchBytes = positive(params.max_patch_bytes, DEFAULT_PATCH_BYTES);
  const maxFiles = positive(params.max_files, DEFAULT_MAX_FILES);
  const context = Math.min(positive(params.context_lines, 3), MAX_CONTEXT_LINES);
  let files: ChangedFile[] = [];
  if (compared.revisions) {
    files = nameStatus(await gitOutput(root, diffArgs(compared, ["--name-status", "-z"], paths)));
    const counts = numstat(await gitOutput(root, diffArgs(compared, ["--numstat", "-z"], paths)));
    for (const file of files) {
      if (!counts.has(file.path)) continue;
      const count = counts.get(file.path);
      if (count) Object.assign(file, count);
      else file.binary = true;
    }
  }
  let untrackedSkipped = 0;
  if (compared.untracked) {
    const names = (await gitOutput(root, ["ls-files", "--others", "--exclude-standard", "-z", "--", ...paths]))
      .split("\0")
      .filter((name) => name && !name.endsWith("/"));
    untrackedSkipped = Math.max(0, names.length - MAX_UNTRACKED_FILES);
    files.push(...names.slice(0, MAX_UNTRACKED_FILES).map((name) => untrackedFile(root, name)));
  }
  files.sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
  const additions = files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
  const totalFiles = files.length;
  files = files.slice(0, maxFiles);
  const withPatch = files.filter((file) => file.status !== "untracked" && !file.binary);
  if (params.include_patch === true && compared.revisions && withPatch.length) {
    const named =
      totalFiles === files.length
        ? paths
        : withPatch.flatMap((file) => [file.path, ...(file.previous_path ? [file.previous_path] : [])]);
    const patches = splitPatches(await gitOutput(root, diffArgs(compared, ["--patch", `--unified=${context}`], named)));
    let budget = MAX_REPLY_PATCH_BYTES;
    for (const file of withPatch) {
      let patch = patches.get(file.path);
      if (patch === undefined) continue;
      const limit = Math.min(maxPatchBytes, budget);
      if (Buffer.byteLength(patch) > limit) {
        const cut = Buffer.from(patch).subarray(0, limit).toString("utf8").replace(/�$/, "");
        const newline = cut.lastIndexOf("\n");
        patch = newline >= 0 ? cut.slice(0, newline + 1) : cut;
        file.patch_truncated = true;
      }
      budget -= Buffer.byteLength(patch);
      if (patch) file.patch = patch;
    }
  }
  return {
    root,
    ...(compared.head ? { head: compared.head } : {}),
    ...(compared.base ? { base: compared.base } : {}),
    files,
    additions,
    deletions,
    total_files: totalFiles,
    files_omitted: totalFiles - files.length,
    ...(untrackedSkipped ? { untracked_skipped: untrackedSkipped } : {}),
  };
}

/** `git.diff {scope, include_patch, paths?, context_lines?}`: GitDiffResult. */
export async function gitDiff(cwd: string, params: Record<string, unknown>) {
  const root = await topLevel(cwd, "git.diff");
  const scope = typeof params.scope === "string" ? params.scope : "uncommitted";
  return { scope, ...(await report(root, await comparison(root, scope), params)) };
}

/// `git.checkpoint.diff {from, to}`: checkpoints are refs the cmux session host captures and
/// records in its own store, which a standalone acpmux never creates, so a turn has none here and
/// the reply lists no files (the pane then shows the turn's own edits).
export async function gitCheckpointDiff(cwd: string, params: Record<string, unknown>) {
  const root = await topLevel(cwd, "git.checkpoint.diff");
  const head = await commit(root, "HEAD");
  return {
    root,
    ...(head ? { head } : {}),
    from: params.from,
    ...(typeof params.to === "string" ? { to: params.to } : {}),
    files: [],
    additions: 0,
    deletions: 0,
    total_files: 0,
    files_omitted: 0,
  };
}

/** `file.search {cwd, query, limit}`: files under `cwd` matching `query`, ranked as the mock daemon ranks them. */
export async function fileSearch(cwd: string, params: Record<string, unknown>) {
  const root = await topLevel(cwd, "git.files.search");
  const prefix = (await gitText(cwd, ["rev-parse", "--show-prefix"])) ?? "";
  const searchRoot = prefix ? path.join(root, prefix.replace(/\/$/, "")) : root;
  const text = typeof params.query === "string" ? params.query.trim() : "";
  if (!text) return { root, search_root: searchRoot, results: [], truncated: false };
  const limit = Math.min(
    typeof params.limit === "number" && params.limit > 0 ? params.limit : SEARCH_DEFAULT_LIMIT,
    SEARCH_MAX_LIMIT,
  );
  // Run in the folder itself, so paths are relative to it and only files under it are listed.
  const listed = await gitOutput(cwd, ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."]);
  const deleted = new Set((await gitOutput(cwd, ["ls-files", "-z", "--deleted", "--", "."])).split("\0"));
  const candidates = [...new Set(listed.split("\0"))].filter(
    (file) => file && !file.endsWith("/") && !deleted.has(file),
  );
  const ranked = candidates
    .flatMap((file) => {
      const hit = fuzzy(file, text);
      return hit ? [{ path: file, matches: hit.matches, score: hit.score }] : [];
    })
    .sort((left, right) => left.score - right.score || left.path.localeCompare(right.path));
  const results: { path: string; matches: number[] }[] = [];
  for (const { path: file, matches } of ranked) {
    if (results.length >= limit) break;
    // A submodule is listed as one path, but it is a folder: never a result.
    if (!isFolder(path.join(searchRoot, file))) results.push({ path: file, matches });
  }
  return { root, search_root: searchRoot, results, truncated: ranked.length > limit };
}

/** `file.list {cwd, path?}`: one folder's children as the session host lists them (git.files.list):
 * tracked and unignored files folded to their first component, folders first, then by name. */
export async function fileList(cwd: string, params: Record<string, unknown>) {
  await topLevel(cwd, "git.files.list");
  const folder = allowedPath(typeof params.path === "string" ? params.path : cwd, [cwd]);
  if (!folder || !isFolder(folder))
    throw new AgentReadError("validation.invalid", "file.list stays inside the chat's folder");
  const listed = await gitOutput(folder, ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."]);
  const entries = new Map<string, "directory" | "file">();
  for (const file of listed.split("\0")) {
    if (!file) continue;
    const [first, ...rest] = file.split("/");
    if (!first) continue;
    const kind = rest.length || isFolder(path.join(folder, first)) ? "directory" : "file";
    if (entries.get(first) !== "directory") entries.set(first, kind);
  }
  const sorted = [...entries].sort(
    ([a, kindA], [b, kindB]) =>
      (kindA === kindB ? 0 : kindA === "directory" ? -1 : 1) ||
      a.toLowerCase().localeCompare(b.toLowerCase()) ||
      a.localeCompare(b),
  );
  return { entries: sorted.map(([name, kind]) => ({ name, kind })), truncated: false };
}

function isFolder(file: string): boolean {
  try {
    return fs.statSync(file).isDirectory();
  } catch {
    return false;
  }
}

/** Answers one read for the folder in `params.cwd`, confined to the slot's folder `slot`. */
export async function agentRead(method: string, params: Record<string, unknown>, slot: string | undefined) {
  if (!(AGENT_READ_METHODS as readonly string[]).includes(method))
    throw new AgentReadError("native.unsupported", `${method} needs the cmux host`);
  const cwd = confinedFolder(params.cwd, slot);
  switch (method as AgentReadMethod) {
    case "git.status":
      return gitStatus(cwd);
    case "git.diff":
      return gitDiff(cwd, params);
    case "git.checkpoint.diff":
      return gitCheckpointDiff(cwd, params);
    case "file.search":
      return fileSearch(cwd, params);
    case "file.list":
      return fileList(cwd, params);
  }
}
