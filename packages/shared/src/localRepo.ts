export const LOCAL_REPO_PREFIX = "local::";

export function encodeLocalRepoValue(path: string): string {
  return `${LOCAL_REPO_PREFIX}${path}`;
}

export function isLocalRepoValue(value?: string | null): value is string {
  return typeof value === "string" && value.startsWith(LOCAL_REPO_PREFIX);
}

export function decodeLocalRepoValue(value?: string | null): string | null {
  if (!isLocalRepoValue(value)) {
    return null;
  }
  return value.slice(LOCAL_REPO_PREFIX.length);
}
