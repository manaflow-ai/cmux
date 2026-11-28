# 2026-11-28-promote-nightly-next-clean-this-job-s-workdir-on-an-owned-mac

Where: `.github/workflows/nightly.yml`, job `promote-nightly-next`, step "Clean this job's workdir on an owned Mac": above `case "${RUNNER_NAME:-}" in *-glaeda|*-glaeda-*) ;; *) [ -d /Users/Shared/cmux-build-fleet ] || exit `.

Before any checkout or secret: an earlier job's files (a DMG, a feed, notes) never reach this one. The runner empties its temp dir itself; the workspace stays between jobs on an owned Mac.
