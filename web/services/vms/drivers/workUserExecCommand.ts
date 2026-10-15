/**
 * The shell prelude every work-user `exec` runs before the caller's command.
 *
 * Public `vm exec` (and everything the Mac drives over it: `vm run`,
 * `vm env ls|rm`, layout, transfers) leaves the provider's `linuxUser` unset,
 * which runs it as the account holding uid 1000. On cmux devbox images that
 * account is the base image's `ubuntu`, renamed to `cmux` with its home moved
 * to `/home/cmux` (images/workUser.ts). The provider still starts the command
 * with `HOME=/home/ubuntu`, a directory that no longer exists, so the command
 * sees a different home from the one its terminals, SSH and `cmux env receive`
 * use: `~/.config/cmux/env` is the wrong file, login shells source nothing,
 * and `cmux vm env ls` reports no machine env.
 *
 * The prelude takes the home from the passwd entry of the effective uid, which
 * is right on every image generation (renamed `cmux`, older `ubuntu` work
 * users, and root-only images alike), and does it server-side so running
 * machines get it on their next exec without a guest update. When the
 * provider's HOME was unusable it also starts the command in the real home,
 * where it would have started had the provider's HOME been right.
 *
 * Then it applies the machine env file, as every login and interactive shell
 * on the machine does, so `vm exec` and `vm run` see `vm env` values and Cloud
 * Secrets. A file that does not parse is skipped rather than allowed to end
 * the command (a dot-script syntax error exits a POSIX `sh`).
 *
 * The same exec carries cmux's own maintenance (`vm env ls|rm`, ports, secrets
 * status, layout, transfers), so the file must not be able to break it: the
 * variables the shell and its tools need to find programs and the work user's
 * files (PATH, HOME, USER, LOGNAME, SHELL, IFS) are kept as they were before
 * the file ran. `cmux env set` refuses those names; this covers a file written
 * by hand or by an older guest.
 *
 * POSIX sh only: the provider runs the command through the guest's shell.
 * Every name it sets is `cmux_exec_`-prefixed and unset before the command.
 */

/** Variables the machine env file cannot change for an exec. */
export const WORK_USER_EXEC_PRESERVED_VARIABLES = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS"] as const;

// `cmux_exec_set_<name>` records whether the variable was set at all, so an
// unset one (IFS usually is) is unset again rather than set to empty.
const savePreserved = WORK_USER_EXEC_PRESERVED_VARIABLES.map(
  (name) => `cmux_exec_set_${name}="\${${name}+1}"; cmux_exec_val_${name}="\${${name}-}"`,
);
const restorePreserved = WORK_USER_EXEC_PRESERVED_VARIABLES.map((name) => {
  const exported = name === "IFS" ? "" : `; export ${name}`;
  return `unset ${name}; if [ -n "$cmux_exec_set_${name}" ]; then ${name}="$cmux_exec_val_${name}"${exported}; fi`;
});
const preservedScratch = WORK_USER_EXEC_PRESERVED_VARIABLES.flatMap((name) => [
  `cmux_exec_set_${name}`,
  `cmux_exec_val_${name}`,
]).join(" ");

export const WORK_USER_EXEC_PRELUDE = [
  `cmux_exec_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"`,
  `if [ -n "$cmux_exec_home" ] && [ -d "$cmux_exec_home" ] && [ "\${HOME:-}" != "$cmux_exec_home" ]; then`,
  `  if [ -z "\${HOME:-}" ] || [ ! -d "$HOME" ] || [ "\${PWD:-/}" = "$HOME" ] || [ "\${PWD:-/}" = / ]; then cd "$cmux_exec_home" 2>/dev/null || :; fi`,
  `  HOME="$cmux_exec_home"; export HOME`,
  `  cmux_exec_user="$(id -un 2>/dev/null)"`,
  `  if [ -n "$cmux_exec_user" ]; then USER="$cmux_exec_user"; LOGNAME="$cmux_exec_user"; export USER LOGNAME; fi`,
  `fi`,
  `cmux_exec_env="$HOME/.config/cmux/env"`,
  // The probe also fails a file that makes one of those names readonly, which
  // would otherwise end the command at the restore.
  `if [ -r "$cmux_exec_env" ] && (. "$cmux_exec_env" && unset ${WORK_USER_EXEC_PRESERVED_VARIABLES.join(" ")}) >/dev/null 2>&1; then`,
  ...savePreserved.map((line) => `  ${line}`),
  `  . "$cmux_exec_env" >/dev/null 2>&1`,
  ...restorePreserved.map((line) => `  ${line}`),
  `fi`,
  `unset cmux_exec_home cmux_exec_user cmux_exec_env ${preservedScratch}`,
].join("\n");

/** The caller's command, unchanged, after the work-user prelude. */
export function workUserExecCommand(command: string): string {
  return `${WORK_USER_EXEC_PRELUDE}\n${command}`;
}
