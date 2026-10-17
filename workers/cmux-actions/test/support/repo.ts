import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import type { RepoFiles } from "../../src/plan/references.ts";

/** Root of the cmux checkout that contains this package. */
export const repoRoot = resolve(import.meta.dirname, "../../../..");

/** The working tree as the run's file system. */
export const workingTree: RepoFiles = {
  read(path) {
    const absolute = join(repoRoot, path);
    return existsSync(absolute) && statSync(absolute).isFile() ? readFileSync(absolute, "utf8") : undefined;
  },
};

export const workflowPaths = (): string[] =>
  readdirSync(join(repoRoot, ".github/workflows"))
    .filter((name) => /\.ya?ml$/.test(name))
    .sort()
    .map((name) => `.github/workflows/${name}`);

export const localActionPaths = (): string[] =>
  readdirSync(join(repoRoot, ".github/actions"))
    .filter((name) => existsSync(join(repoRoot, ".github/actions", name, "action.yml")))
    .sort()
    .map((name) => `.github/actions/${name}`);

export const SHA_A = "a".repeat(40);
export const SHA_B = "b".repeat(40);
export const SHA_C = "c".repeat(40);
export const REPOSITORY = "manaflow-ai/cmux";
