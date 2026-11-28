# 2026-11-24-fast-tier-cargo-3

Above the step `Test the warm cargo target` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

A persistent pool runner keeps this job's whole target between its jobs and gives each source
whose bytes are unchanged its recorded mtime back, so cargo rebuilds only the crates a change
reaches and their dependents (scripts/ci/pool-warm-target.sh); on Blacksmith a sticky disk holds it.
The warm target's own test, where cargo is: unchanged bytes stay fresh, a changed crate and its
dependents rebuild, an unrecorded job leaves nothing to trust (a three-crate workspace, ~5 s).
