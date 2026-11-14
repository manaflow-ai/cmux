/**
 * The npm cache baked into the image: a first `npm install` on a fresh machine finds the usual web packages
 * already downloaded. Measured by first-session.ts before it was baked (run 42087098855): a first install of
 * PREFILL_NODE_DEPS went from 16.4 s to 4.9 s.
 *
 * Bounded twice: the cache is emptied first and then holds only what one install of PREFILL_NODE_DEPS (and their
 * dependencies) puts in it, and the bake step fails when the result is over NPM_CACHE_CAP_MB. install-census.ts adds at
 * most MAX_MEASURED names to the list.
 * No package code runs: the install passes --ignore-scripts, so no lifecycle script of any (transitive) package
 * executes in the image build; npm only downloads and verifies tarballs into the content-addressed cache, which a
 * person's own install checks against the registry's integrity hashes as it would any download. The versions are what the registry resolves
 * at bake time, so the cache is as fresh as the agents layer; an older version only costs a download.
 * clean.py keeps exactly ~/.npm/_cacache (the content and index) and drops npm's logs.
 */
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { sq } from "./lock";
import prefillDeps from "./prefill-deps.json";

/** An npm registry name (`react`, `@types/node`): lowercase, no path, URL or version. */
export const NPM_NAME = /^(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/;

/**
 * What the npm cache is filled with, unpinned, as a person's new project resolves them (prefill-deps.json):
 * `base`, a web app's usual first installs, then `measured`, the packages agents installed most on machines
 * whose Usage Patterns count installs (install-census.ts writes it from those counts).
 */
export function prefillNodeDeps(lists: { base: readonly string[]; measured: readonly string[] } = prefillDeps.npm): string[] {
  const names = [...new Set([...lists.base, ...lists.measured])];
  const bad = names.filter((name) => !NPM_NAME.test(name));
  if (bad.length > 0) throw new Error(`prefill-deps.json names that are not npm registry names: ${bad.join(", ")}`);
  return names;
}

export const PREFILL_NODE_DEPS: readonly string[] = prefillNodeDeps();

/** The cache directory npm uses for the work user, the one directory clean.py keeps. */
export const NPM_CACHE_DIR = `${DEVBOX_WORK_HOME}/.npm/_cacache`;

/** The most the baked npm cache may take on disk. */
export const NPM_CACHE_CAP_MB = 300;

/**
 * Fill the work user's npm cache with one install of PREFILL_NODE_DEPS; print `npm-cache-mb N`; fail over the cap.
 * POSIX sh: the guest runs a step with /bin/sh (dash), which has no pipefail (run 42104967506).
 */
export function npmCachePrefillCommand(): string {
  const dir = "/tmp/cmux-npm-prefill";
  const install = [
    `rm -rf ${dir} ${NPM_CACHE_DIR} && mkdir -p ${dir} && cd ${dir}`,
    `printf '%s' '{"name":"npm-prefill","private":true}' > package.json`,
    `npm install --ignore-scripts --no-audit --no-fund --loglevel=error ${PREFILL_NODE_DEPS.join(" ")} >/dev/null`,
    `cd / && rm -rf ${dir}`,
  ].join(" && ");
  return [
    "set -eu",
    `runuser -u ${DEVBOX_WORK_USER} -- bash -lc ${sq(install)}`,
    `mb=$(${npmCacheSizeCommand()})`,
    'echo "npm-cache-mb $mb"',
    `if [ "$mb" -gt ${NPM_CACHE_CAP_MB} ]; then echo "npm cache is $mb MB, over the ${NPM_CACHE_CAP_MB} MB cap" >&2; exit 1; fi`,
  ].join("\n");
}

/** The baked npm cache's size in MB (0 when there is none). */
export function npmCacheSizeCommand(): string {
  return `{ du -sm ${NPM_CACHE_DIR} 2>/dev/null || echo 0; } | cut -f1`;
}
