#!/usr/bin/env bash
set -euo pipefail

# One Linux proof for the local↔Cloud transfer matrix and the route chooser.
# The journey tests start real cmux-tui/acpmux daemons; the acpmux selectors
# exercise the same auto target ranking and its human-readable reasons.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root/cmux-tui"

cargo test --locked -p cmux-tui --test cloud_move_journey --no-default-features -- --nocapture
cargo test --locked -p cmux-tui --test bring_back_journey --no-default-features -- --nocapture
cargo test --locked -p cmux-tui --test cloud_move_git_journey --no-default-features -- --nocapture
cargo test --locked -p cmux-tui --test transfer_fetch_journey --no-default-features -- --nocapture

# Auto chat placement's machine choice is shared with session move's `--host auto`.
# Keep the selectors explicit so a green run proves both the pick and the reason
# shown for passed-over or unreachable hosts.
cargo test --locked -p acpmux --lib auto_picks_the_peer_with_most_room_never_this_machine_and_spreads_a_batch
cargo test --locked -p acpmux --lib auto_passes_over_a_host_a_fresh_ssh_cannot_reach
cargo test --locked -p acpmux --lib auto_passes_over_a_host_short_of_disk_unless_every_host_is

