#!/usr/bin/env bash
# Keep apt from restarting the runner's services: needrestart lists them instead (mode `l`).
#
# `playwright install --with-deps` runs apt-get, and Ubuntu's needrestart then restarts every service still holding a
# library apt replaced. On the cmux-linux pool that includes cmux-git-mirror.service, a oneshot (TimeoutStartSec=1800)
# whose `systemctl restart` waits for a whole mirror fetch: 6 of 17 react-apps-check (1) pull request jobs on
# 2026-11-25 21:49-22:18Z sat 900 s on "systemctl restart cmux-git-mirror.service packagekit.service" (job
# 139533404435: 21:56:48 to 22:11:48), half of each job's 30 min. A CI job needs no service restarted.
#
# Run it before the install. Idempotent, no-op where needrestart is absent or sudo needs a password;
# CI_APT_NO_SERVICE_RESTARTS=0 (a repository variable in ci-web.yml) leaves needrestart as it was.
set -u
[ "${CI_APT_NO_SERVICE_RESTARTS:-1}" != 0 ] || { echo "apt-no-service-restarts: off (CI_APT_NO_SERVICE_RESTARTS=0)"; exit 0; }
[ "$(uname -s)" = Linux ] && [ -d /etc/needrestart ] || exit 0
conf=/etc/needrestart/conf.d/90-cmux-ci-list-only.conf
[ -f "$conf" ] && exit 0
if printf '%s\n' "# cmux CI (scripts/ci/apt-no-service-restarts.sh): list services, restart none" "\$nrconf{restart} = 'l';" |
  sudo -n tee "$conf" >/dev/null 2>&1; then
  echo "apt-no-service-restarts: needrestart lists services, restarts none ($conf)"
else
  echo "apt-no-service-restarts: could not write $conf; needrestart unchanged"
fi
exit 0
