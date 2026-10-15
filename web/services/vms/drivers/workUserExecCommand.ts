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
 * POSIX sh only: the provider runs the command through the guest's shell.
 * Every name it sets is `cmux_exec_`-prefixed and unset before the command.
 */
export const WORK_USER_EXEC_PRELUDE = [
  `cmux_exec_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"`,
  `if [ -n "$cmux_exec_home" ] && [ -d "$cmux_exec_home" ] && [ "\${HOME:-}" != "$cmux_exec_home" ]; then`,
  `  if [ -z "\${HOME:-}" ] || [ ! -d "$HOME" ] || [ "\${PWD:-/}" = "$HOME" ] || [ "\${PWD:-/}" = / ]; then cd "$cmux_exec_home" 2>/dev/null || :; fi`,
  `  HOME="$cmux_exec_home"; export HOME`,
  `  cmux_exec_user="$(id -un 2>/dev/null)"`,
  `  if [ -n "$cmux_exec_user" ]; then USER="$cmux_exec_user"; LOGNAME="$cmux_exec_user"; export USER LOGNAME; fi`,
  `fi`,
  `cmux_exec_env="$HOME/.config/cmux/env"`,
  `if [ -r "$cmux_exec_env" ] && (. "$cmux_exec_env") >/dev/null 2>&1; then . "$cmux_exec_env" >/dev/null 2>&1; fi`,
  `unset cmux_exec_home cmux_exec_user cmux_exec_env`,
].join("\n");

/** The caller's command, unchanged, after the work-user prelude. */
export function workUserExecCommand(command: string): string {
  return `${WORK_USER_EXEC_PRELUDE}\n${command}`;
}
