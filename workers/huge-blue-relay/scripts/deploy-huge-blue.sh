#!/usr/bin/env bash
# Run on Huge Blue after syncing a committed snapshot and staging-only DB env.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
[[ "$root" == /home/leo/Projects/cmux-huge-blue-relay ]]
[[ -r "$root/staging.env" ]]
chmod 600 "$root/staging.env"
cd "$root/web"
bun install --frozen-lockfile --production
mkdir -p "$HOME/.config/systemd/user"
install -m 644 "$root/workers/huge-blue-relay/systemd/cmux-staging-relay.service" "$HOME/.config/systemd/user/"
install -m 644 "$root/workers/huge-blue-relay/systemd/cmux-staging-relay-proxy.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable cmux-staging-relay.service cmux-staging-relay-proxy.service
systemctl --user restart cmux-staging-relay.service cmux-staging-relay-proxy.service
# Change only the staging listener owned by this deploy; never reset other ports.
sudo tailscale serve --https=443 off
sudo tailscale serve --bg --https=443 http://127.0.0.1:1338
systemctl --user show -p ActiveState -p NRestarts -p ExecMainStatus cmux-staging-relay.service cmux-staging-relay-proxy.service
