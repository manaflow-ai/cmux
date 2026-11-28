# 2026-11-28-clean-this-job-s-workdir-on-an-owned-mac

Where: `.github/workflows/nightly.yml`, Clean this job's workdir on an owned Mac.

Before any checkout or secret: an earlier job's files (a DMG, a feed, notes) never reach this one. The runner empties its temp dir itself; the workspace stays between jobs on an owned Mac.
