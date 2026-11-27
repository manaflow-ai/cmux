/**
 * The previous source a compatibility script runs against, committed under scripts/compat-baselines/<sha>/.
 *
 * These scripts used to `git show` (and on a miss `git fetch`) the pinned commit at test time, so a slow
 * GitHub git endpoint turned the cmux-vm deploy gate red with no code at fault (run 45746933233, 11-26:
 * "cannot fetch the pinned previous ledger"). A pinned commit never changes, so its file is a fixture.
 * Add one with: curl -fsS -o scripts/compat-baselines/SHA/FILE.baseline \
 *   https://raw.githubusercontent.com/manaflow-ai/cmux/SHA/workers/cmux-vm/src/limits/FILE
 */
import { existsSync, readFileSync } from "node:fs";

export function readBaseline(sha: string, file: string): string {
  const path = new URL(`./compat-baselines/${sha}/${file}.baseline`, import.meta.url);
  if (!existsSync(path)) {
    throw Error(`no committed baseline ${sha}/${file}; add scripts/compat-baselines/${sha}/${file}.baseline (see scripts/compat-baseline.ts)`);
  }
  return readFileSync(path, "utf8");
}
