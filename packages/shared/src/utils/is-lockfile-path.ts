import type { ReplaceDiffEntry } from "../diff-types";

const LOCKFILE_BASENAMES = new Set([
  "pnpm-lock.yaml",
  "yarn.lock",
  "package-lock.json",
  "pipfile.lock",
  "poetry.lock",
  "gemfile.lock",
  "composer.lock",
  "cargo.lock",
  "bun.lock",
  "bun.lockb",
  "uv.lock",
]);

function stripRepoPrefix(rawPath: string): string {
  const normalized = rawPath.replace(/\\/g, "/");
  const colonIndex = normalized.indexOf(":");
  if (colonIndex > -1 && colonIndex < normalized.length - 1) {
    const prefix = normalized.slice(0, colonIndex);
    if (!prefix.includes("/") && !prefix.includes("\\")) {
      return normalized.slice(colonIndex + 1);
    }
  }
  return normalized;
}

export function isLockfilePath(path: string | undefined | null): boolean {
  if (!path) {
    return false;
  }
  const trimmed = path.trim();
  if (!trimmed) {
    return false;
  }
  const withoutPrefix = stripRepoPrefix(trimmed);
  const segments = withoutPrefix.split("/").filter(Boolean);
  const basename = segments.at(-1)?.toLowerCase() ?? "";
  return LOCKFILE_BASENAMES.has(basename);
}

export function isLockfileDiffEntry(entry: ReplaceDiffEntry): boolean {
  return isLockfilePath(entry.filePath) || isLockfilePath(entry.oldPath);
}
