/**
 * The npm cache baked into the image: a first `npm install` on a fresh machine finds the usual web packages
 * already downloaded. Measured by first-session.ts before it was baked (run 42087098855): a first install of
 * PREFILL_NODE_DEPS went from 16.4 s to 4.9 s.
 *
 * Bounded twice: the cache holds only what one install of PREFILL_NODE_DEPS (and their dependencies) puts in it,
 * and the bake step fails when the result is over NPM_CACHE_CAP_MB. The versions are what the registry resolves
 * at bake time, so the cache is as fresh as the agents layer; an older version only costs a download.
 * clean.py keeps exactly ~/.npm/_cacache (the content and index) and drops npm's logs.
 */
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { sq } from "./lock";

/** A web app's usual first installs; unpinned, as a person's new project resolves them. */
export const PREFILL_NODE_DEPS = ["react", "react-dom", "vite", "typescript", "@types/react", "@types/node", "eslint", "prettier", "zod", "vitest"] as const;

/** The cache directory npm uses for the work user, the one directory clean.py keeps. */
export const NPM_CACHE_DIR = `${DEVBOX_WORK_HOME}/.npm/_cacache`;

/** The most the baked npm cache may take on disk. */
export const NPM_CACHE_CAP_MB = 300;

/** Fill the work user's npm cache with one install of PREFILL_NODE_DEPS; print `npm-cache-mb N`; fail over the cap. */
export function npmCachePrefillCommand(): string {
  const dir = "/tmp/cmux-npm-prefill";
  const install = [
    `rm -rf ${dir} && mkdir -p ${dir} && cd ${dir}`,
    `printf '%s' '{"name":"npm-prefill","private":true}' > package.json`,
    `npm install --no-audit --no-fund --loglevel=error ${PREFILL_NODE_DEPS.join(" ")} >/dev/null`,
    `cd / && rm -rf ${dir}`,
  ].join(" && ");
  return [
    "set -euo pipefail",
    `runuser -u ${DEVBOX_WORK_USER} -- bash -lc ${sq(install)}`,
    `mb=$(du -sm ${NPM_CACHE_DIR} | cut -f1)`,
    'echo "npm-cache-mb $mb"',
    `if [ "$mb" -gt ${NPM_CACHE_CAP_MB} ]; then echo "npm cache is $mb MB, over the ${NPM_CACHE_CAP_MB} MB cap" >&2; exit 1; fi`,
  ].join("\n");
}
