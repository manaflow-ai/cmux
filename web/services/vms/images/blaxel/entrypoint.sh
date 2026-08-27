#!/usr/bin/env bash
# Entrypoint for the cmux-devbox Blaxel image. Blaxel requires the sandbox API
# to be launched here and the script to stay alive with `wait`.
set -u

# Supervise the sandbox API: it is the machine's control plane, and without a
# restart a crashed API leaves a "running" machine whose filesystem/process
# operations all fail.
(
  while true; do
    /usr/local/bin/sandbox-api >>/var/log/cmux-sandbox-api.log 2>&1
    echo "sandbox-api exited (rc=$?); restarting" >>/var/log/cmux-sandbox-api.log
    sleep 1
  done
) &

# Wait until the sandbox API answers on 8080 before anything else runs.
for _ in $(seq 1 100); do
  nc -z 127.0.0.1 8080 >/dev/null 2>&1 && break
  sleep 0.2
done

# Blaxel's rootfs transform does not carry /home/cua over from the image (the
# runtime mounts a fresh root-owned dir there), so recreate the desktop user's
# home on every boot before dropping privileges. Ownership is fixed on the
# exact paths created here, never recursively: the home can hold user data and
# an unbounded walk would delay boot. The "First Run" marker pre-accepts
# Chrome's first-run/ToS dialog, so the dock's Chrome opens straight to a page
# on a fresh machine and in anything resumed from its snapshot.
mkdir -p "/home/cua/.config/google-chrome"
touch "/home/cua/.config/google-chrome/First Run"
chown cua:cua /home/cua /home/cua/.config /home/cua/.config/google-chrome \
  "/home/cua/.config/google-chrome/First Run"

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
