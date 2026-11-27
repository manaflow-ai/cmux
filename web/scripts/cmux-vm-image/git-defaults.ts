/**
 * System git defaults for a cmux Cloud machine (RFD 0065 piece 3, "Git defaults in the VM image"):
 * checkout 13.6 s to 5.0 s and status 0.31 s to 0.06 s on a big repo. They go in /etc/gitconfig, so
 * a person's own --global or repo config still wins.
 */

/** key, value: `scalar clone`'s set plus parallel checkout. */
export const GIT_DEFAULTS: ReadonlyArray<readonly [string, string]> = [
  ["checkout.workers", "0"], // 0 = one worker per CPU
  ["core.untrackedCache", "true"],
  ["index.version", "4"],
  ["core.preloadIndex", "true"],
  ["feature.manyFiles", "true"],
];

/** Sets each default in /etc/gitconfig, then reads each back from the system file. */
export function gitDefaultsCommand(): string {
  return [
    ...GIT_DEFAULTS.map(([k, v]) => `git config --system ${k} ${v}`),
    ...GIT_DEFAULTS.map(([k, v]) => `test "$(git config --system --get ${k})" = ${v}`),
    "echo git-defaults-set",
  ].join(" && ");
}
