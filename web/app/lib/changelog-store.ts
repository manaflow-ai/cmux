import fs from "node:fs";
import path from "node:path";
import { ChangelogStore } from "./changelog";

const sourcePath = resolveChangelogPath(process.cwd(), fs.existsSync);

export const changelogStore = new ChangelogStore({
  fingerprint() {
    const stats = fs.statSync(sourcePath);
    return `${stats.mtimeMs}:${stats.ctimeMs}:${stats.size}`;
  },
  read() {
    return fs.readFileSync(sourcePath, "utf-8");
  },
});

function resolveChangelogPath(
  workingDirectory: string,
  exists: (candidate: string) => boolean,
): string {
  const candidates = [
    path.resolve(workingDirectory, "..", "CHANGELOG.md"),
    path.resolve(workingDirectory, "CHANGELOG.md"),
  ];
  const changelog = candidates.find(exists);
  if (!changelog) {
    throw new Error("Changelog unavailable");
  }
  return changelog;
}
