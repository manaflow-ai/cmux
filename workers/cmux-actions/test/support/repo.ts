import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import type { RepoFiles } from "../../src/plan/references.ts";

/** Root of the cmux checkout that contains this package. */
export const repoRoot = resolve(import.meta.dirname, "../../../..");

/** A directory on disk as a run's file system, paths relative to `root`. */
const treeAt = (root: string): RepoFiles => ({
  read(path) {
    const absolute = join(root, path);
    return existsSync(absolute) && statSync(absolute).isFile() ? readFileSync(absolute, "utf8") : undefined;
  },
});

/** The working tree as the run's file system. */
export const workingTree: RepoFiles = treeAt(repoRoot);

/**
 * A frozen repository tree under test/fixtures, owned by the tests. Exact-plan
 * tests read these instead of the working tree, so they test the engine and
 * pass on any branch whatever its live workflows look like.
 */
export const fixtureTree = (name: string): RepoFiles => treeAt(resolve(import.meta.dirname, "../fixtures", name));

export const workflowPaths = (): string[] =>
  readdirSync(join(repoRoot, ".github/workflows"))
    .filter((name) => /\.ya?ml$/.test(name))
    .sort()
    .map((name) => `.github/workflows/${name}`);

/** Every directory under .github/actions, whether or not it holds an action file. */
export const actionDirectories = (): string[] => {
  const root = join(repoRoot, ".github/actions");
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => `.github/actions/${entry.name}`)
    .sort();
};

/** Directories under .github/actions that hold an `action.yml` or `action.yaml`. */
export const localActionPaths = (): string[] =>
  actionDirectories().filter((directory) => ["action.yml", "action.yaml"].some((name) => existsSync(join(repoRoot, directory, name))));

export const SHA_A = "a".repeat(40);
export const SHA_B = "b".repeat(40);
export const SHA_C = "c".repeat(40);
export const REPOSITORY = "manaflow-ai/cmux";
