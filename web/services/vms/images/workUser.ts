/**
 * The account and machine name every cmux Cloud machine promises, shared by
 * the image definition (services/vms/images/devbox), the bake and verify
 * scripts, the cmux-tui daemon contract, and the tests that pin all of them.
 *
 * ONE account owns everything a person touches on a machine: the terminals the
 * cmux-tui daemon opens, the desktop session, the provider's default exec and
 * SSH user, and whatever an agent writes. It is not root — coding agents
 * refuse to run as root (`claude --dangerously-skip-permissions` exits before
 * it starts) — and it holds passwordless sudo, so administering the machine is
 * one `sudo` away.
 *
 * It is the base image's uid-1000 account, renamed rather than added:
 * Freestyle's exec API resolves its default `linuxUser` to "the account
 * holding uid 1000", so a rename keeps the provider's own surfaces landing in
 * the same home as cmux's terminals instead of splitting the machine between
 * two near-identical accounts.
 *
 * `ubuntu` stays a second name for the same account (devboxUbuntuAliasCommand):
 * the Freestyle docs, SDK examples and editor URLs name `ubuntu`, so
 * `ssh <vm>+ubuntu@...`, `exec({ linuxUser: "ubuntu" })` and an identity grant
 * for `ubuntu` must land in the work user's home, with its groups and sudo.
 */

/** The work user: uid 1000 on every cmux Cloud machine. */
export const DEVBOX_WORK_USER = "cmux";
export const DEVBOX_WORK_HOME = `/home/${DEVBOX_WORK_USER}`;
export const DEVBOX_WORK_UID = 1000;

/**
 * Renames the base image's uid-1000 account to the work user. Idempotent: a
 * re-bake over an already-renamed machine skips the rename and re-asserts the
 * rest. Run as root, before any layer that writes into the home or names the
 * user — the NOPASSWD policy the base ships names the OLD account, so it is
 * replaced here rather than left dangling. The machine's own name is a
 * separate contract (services/vms/images/identity.ts).
 */
export function devboxWorkUserSetupCommand(): string {
  const user = DEVBOX_WORK_USER;
  const home = DEVBOX_WORK_HOME;
  return `
set -e
if ! id -u ${user} >/dev/null 2>&1; then
  old="$(getent passwd ${DEVBOX_WORK_UID} | cut -d: -f1)"
  test -n "$old"
  pkill -KILL -u "$old" 2>/dev/null || true
  sleep 1
  usermod -l ${user} -d ${home} -m "$old"
  groupmod -n ${user} "$old"
fi
# The base's own NOPASSWD policy names the old account. Drop every sudoers
# drop-in that does not name the work user, then write ours.
for f in /etc/sudoers.d/*; do
  [ -f "$f" ] || continue
  grep -q '^${user}[[:space:]]' "$f" || rm -f "$f"
done
printf '${user} ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/91-cmux-work-user
chmod 0440 /etc/sudoers.d/91-cmux-work-user
# Ubuntu's user-private-group rule (USERGROUPS_ENAB yes) hands the account a
# 002 umask, so every directory it creates is group-writable. cmux-tui refuses
# to store its Noise identity under a group-writable ancestor ("secure
# directory ... has an ancestor writable by other users"), which is the daemon
# on this machine, so the account uses root's 022 instead. Existing directories
# are re-hardened here because the base image shipped them at 775.
sed -i 's/^USERGROUPS_ENAB.*/USERGROUPS_ENAB no/' /etc/login.defs
grep -q '^USERGROUPS_ENAB no$' /etc/login.defs
find ${home} -type d -exec chmod g-w,o-w {} +
[ "$(find ${home} -type d \\( -perm -g+w -o -perm -o+w \\) | wc -l)" = 0 ]
[ "$(sudo -n -u ${user} sh -c umask)" = 0022 ]
# Prove the contract rather than trusting the steps above.
[ "$(id -u ${user})" = ${DEVBOX_WORK_UID} ]
[ "$(getent passwd ${DEVBOX_WORK_UID} | cut -d: -f1)" = ${user} ]
[ "$(getent passwd ${user} | cut -d: -f6)" = ${home} ]
test -d ${home}
sudo -n -u ${user} sudo -n true
echo work-user-ok
`.trim();
}

/** The base image's account name, kept as a second name for the work user. */
export const DEVBOX_UBUNTU_ALIAS = "ubuntu";

/**
 * Makes `cmux` and `ubuntu` two names for one account: whichever owns uid
 * 1000 stays first in /etc/passwd (so uid 1000 keeps resolving to it), and the
 * other gets the same uid, primary group, home, shell, password field,
 * supplementary groups and passwordless sudo (its own drop-in,
 * 92-cmux-account-alias), plus a /home/<name> link to the
 * shared home. Current images own uid 1000 as `cmux` and gain `ubuntu`;
 * machines baked before the rename own it as `ubuntu` and gain `cmux`.
 * Idempotent, and it re-syncs the groups, so the bake runs it after every
 * layer that adds groups and it is safe to run again on a running machine.
 */
export function devboxUbuntuAliasCommand(): string {
  return `
set -e
primary="$(getent passwd ${DEVBOX_WORK_UID} | cut -d: -f1)"
case "$primary" in
  ${DEVBOX_WORK_USER}) alias=${DEVBOX_UBUNTU_ALIAS} ;;
  ${DEVBOX_UBUNTU_ALIAS}) alias=${DEVBOX_WORK_USER} ;;
  *) echo "uid ${DEVBOX_WORK_UID} is '$primary', not ${DEVBOX_WORK_USER} or ${DEVBOX_UBUNTU_ALIAS}" >&2; exit 1 ;;
esac
home="$(getent passwd "$primary" | cut -d: -f6)"
test -d "$home"
if ! getent passwd "$alias" >/dev/null 2>&1; then
  useradd --non-unique --uid ${DEVBOX_WORK_UID} --gid "$(id -g "$primary")" --no-create-home --home-dir "$home" --shell "$(getent passwd "$primary" | cut -d: -f7)" "$alias"
fi
[ "$(id -u "$alias")" = ${DEVBOX_WORK_UID} ]
usermod -p "$(getent shadow "$primary" | cut -d: -f2)" "$alias"
usermod -G "$(id -nG "$primary" | xargs -n1 | grep -vx "$primary" | paste -sd, -)" "$alias"
# The alias gets its own drop-in; the primary account's policy is left as is.
echo "$alias ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/92-cmux-account-alias
chmod 0440 /etc/sudoers.d/92-cmux-account-alias
visudo -cq
if [ ! -L "/home/$alias" ] && [ "/home/$alias" != "$home" ]; then
  rmdir "/home/$alias" 2>/dev/null || true
  test ! -e "/home/$alias"
  ln -s "$home" "/home/$alias"
fi
# Prove the contract rather than trusting the steps above.
[ "$(getent passwd ${DEVBOX_WORK_UID} | cut -d: -f1)" = "$primary" ]
[ "$(getent passwd "$alias" | cut -d: -f6)" = "$home" ]
[ "$(id -nG "$alias" | xargs -n1 | grep -vx "$primary" | sort | paste -sd, -)" = "$(id -nG "$primary" | xargs -n1 | grep -vx "$primary" | sort | paste -sd, -)" ]
[ "$(readlink -f "/home/$alias")" = "$(readlink -f "$home")" ]
for name in "$primary" "$alias"; do
  [ "$(sudo -n -u "$name" sh -c 'echo $HOME')" = "$home" ]
  sudo -n -u "$name" sudo -n true
done
echo ubuntu-alias-ok
`.trim();
}
