#!/usr/bin/env bash
# Entrypoint for the cmux-devbox Blaxel image. Blaxel requires the sandbox API
# to be launched here and the script to stay alive with `wait`.
set -u

/usr/local/bin/sandbox-api &

# Wait until the sandbox API answers on 8080 before anything else runs.
for _ in $(seq 1 100); do
  nc -z 127.0.0.1 8080 >/dev/null 2>&1 && break
  sleep 0.2
done

# Blaxel's rootfs transform does not carry /home/cua over from the image, so
# recreate the desktop user's home on every boot before dropping privileges.
# The "First Run" marker pre-accepts Chrome's first-run/ToS dialog, so the
# dock's Chrome opens straight to a page on a fresh machine and in anything
# resumed from its snapshot.
mkdir -p "/home/cua/.config/google-chrome"
touch "/home/cua/.config/google-chrome/First Run"
chown -R cua:cua /home/cua

# Bring the desktop up, and bring it back if a component dies. The driver's
# VNC heal covers bootstrap/resurrect only; this loop covers mid-life crashes.
# start-vnc.sh is idempotent, so re-running it against a healthy desktop is a
# cheap no-op probe.
(
  while true; do
    runuser -u cua -- env HOME=/home/cua USER=cua DISPLAY=:1 \
      bash /usr/local/bin/start-vnc.sh >>/var/log/cmux-desktop.log 2>&1 || true
    sleep 30
  done
) &

wait
