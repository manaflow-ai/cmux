/**
 * GitHub for git and gh on a cmux Cloud machine (plans/cmux-next/cloud-github-auth-DESIGN.md):
 * no GitHub secret at rest. Each git or gh run asks the machine's Cloud agent (cmux-host
 * cloud/github.rs) for a short-lived installation token of the team's cmux GitHub App, for one
 * repository and the permissions the run needs; the token lives only in that process.
 *
 * - git: a system credential helper for https://github.com (`cmux github credential`), in
 *   /etc/cmux/gitconfig, included from /etc/gitconfig. A person's own `--global` helper (a
 *   `gh auth setup-git` writes an empty `helper =` first) replaces it.
 * - gh: a shim first on PATH that runs `cmux github gh --auto` when the agent socket is there,
 *   else the store's gh. `--auto` leaves a person's own `GH_TOKEN` or gh login untouched.
 */
import { CURRENT_BIN } from "./lock";

/** The Cloud agent's socket (cmux-host cloud/wire.rs AGENT_SOCKET; root:cmux 0660). */
export const AGENT_SOCKET = "/run/cmux-vm-agent/agent.sock";
/** Ahead of the store on every PATH the machine hands out (bake.ts STORE_PATH and the login profile). */
export const GITHUB_SHIM_DIR = "/opt/cmux/github/bin";
export const GH_SHIM = `${GITHUB_SHIM_DIR}/gh`;
export const GITHUB_GITCONFIG = "/etc/cmux/gitconfig";

const sq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/** The `gh` shim. The paths are parameters so a test runs it against stand-ins. */
export function ghShimScript(opts: { realGh?: string; cmux?: string; socket?: string } = {}): string {
  const { realGh = `${CURRENT_BIN}/gh`, cmux = `${CURRENT_BIN}/cmux`, socket = AGENT_SOCKET } = opts;
  return [
    "#!/bin/sh",
    "# cmux (images/cmux-vm, managed, do not edit): gh with a short-lived GitHub App token for one",
    "# repo from this machine's Cloud agent, unless you have your own GH_TOKEN or gh login.",
    `if [ -S ${sq(socket)} ] && [ -x ${sq(cmux)} ]; then`,
    `  CMUX_GITHUB_GH_REAL=${sq(realGh)} exec ${sq(cmux)} github gh --auto -- "$@"`,
    "fi",
    `exec ${sq(realGh)} "$@"`,
    "",
  ].join("\n");
}

/** /etc/cmux/gitconfig: the store's cmux as git's helper for github.com, with the repo path. */
export function githubGitconfig(cmux = `${CURRENT_BIN}/cmux`): string {
  return [
    "# cmux (images/cmux-vm, managed, do not edit): git gets a short-lived GitHub App token per repo",
    "# from this machine's Cloud agent. Your own --global helper for github.com replaces this one.",
    '[credential "https://github.com"]',
    `\thelper = !${cmux} github credential`,
    "\tuseHttpPath = true",
    "",
  ].join("\n");
}

/** The files the bake writes before githubAuthLinkCommand runs. */
export function githubAuthFiles(): Array<{ path: string; text: string; mode: number }> {
  return [
    { path: GH_SHIM, text: ghShimScript(), mode: 0o755 },
    { path: GITHUB_GITCONFIG, text: githubGitconfig(), mode: 0o644 },
  ];
}

/** Includes the gitconfig from /etc/gitconfig once and checks what a login shell then sees. */
export function githubAuthLinkCommand(storePath: string): string {
  return [
    // The provider's file API may make the dirs as the work user; root's PATH (the host unit) holds this one.
    `chown root:root /opt/cmux/github ${GITHUB_SHIM_DIR} ${GH_SHIM} ${GITHUB_GITCONFIG} && chmod 0755 /opt/cmux/github ${GITHUB_SHIM_DIR}`,
    `test "$(stat -c %U:%a ${GITHUB_SHIM_DIR})" = root:755 && test "$(stat -c %U ${GH_SHIM})" = root`,
    `sh -n ${GH_SHIM}`,
    `{ git config --system --get-all include.path 2>/dev/null | grep -qxF ${GITHUB_GITCONFIG} || git config --system --add include.path ${GITHUB_GITCONFIG}; }`,
    `test "$(git config --system --includes --get-all credential.https://github.com.helper)" = ${sq(`!${CURRENT_BIN}/cmux github credential`)}`,
    `test "$(env -i PATH=${storePath} sh -c 'command -v gh')" = ${GH_SHIM}`,
    `test "$(env -i HOME=/root PATH=/usr/bin:/bin bash -lc 'command -v gh')" = ${GH_SHIM}`,
    `${CURRENT_BIN}/cmux github --help | grep -qF -- 'gh --auto'`,
    "echo github-auth-linked",
  ].join(" && ");
}
