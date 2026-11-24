#!/bin/sh
# install.sh DIR [BINARY]: put the Cloud Chief host units on this machine, disabled. Run as root.
# The image bake runs it with the image's own optchat-chief (/opt/cmux/current/bin/optchat-chief);
# cloud-chief-check.ts runs the same file on a fresh machine with a pull request's build.
#   DIR     this folder (the units, cmux-chief-host, cmux-chief-update)
#   BINARY  the first build `current` points at; without one the unit fetches the newest on its first start
set -eu
dir="$1"
bin="${2:-}"
install -D -m 0755 "$dir/cmux-chief-update" /usr/local/sbin/cmux-chief-update
install -D -m 0755 "$dir/cmux-chief-host" /usr/local/lib/cmux-chief/cmux-chief-host
for u in cmux-chief.service cmux-chief-update.service cmux-chief-update.timer; do
  install -D -m 0644 "$dir/$u" "/etc/systemd/system/$u"
done
install -d -m 0755 /var/lib/cmux-chief /var/lib/cmux-chief/store
if [ -n "$bin" ]; then
  "$bin" --version >/dev/null
  ln -sfn "$bin" /var/lib/cmux-chief/current.new
  mv -T /var/lib/cmux-chief/current.new /var/lib/cmux-chief/current
fi
# On PATH for the work user and its agents, at whatever build `current` names.
ln -sfn /var/lib/cmux-chief/current /usr/local/bin/optchat-chief
systemctl daemon-reload
# Disabled by default: pairing writes the install file, then `systemctl enable --now cmux-chief.service`.
systemctl disable cmux-chief.service cmux-chief-update.timer >/dev/null 2>&1 || true
echo "chief-host-installed $(/var/lib/cmux-chief/current --version 2>/dev/null || echo 'no build yet')"
