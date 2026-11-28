# daemon-test: lease the mini's seed root

Above `daemon-test: Keep Swift package builds on this owned Mac` in `.github/workflows/cmux-next.yml`
(it amends [note-251](../cmux-next-workflow-notes.md#note-251)).

Lease a build root after Xcode selection, as the fast
tier does (owned_spm_scratch.py lease): the mini's seed root when it is free and
CI_DAEMON_TEST_OWNED_SEED (else CI_FAST_TIER_OWNED_SEED) is not "0", else a shared
root, else this runner's own linked build as before. `link` alone started cold on
the minis ("starts cold (evicted, 0.0 GiB kept)", generated-files fixture logs of
2026-11-14), so every daemon test compiled the package from nothing: 1,558 s on
cmux22-glaeda-2 (job 136775309202, 2026-11-21) against the fast tier's seeded 6.9
min. Every step that builds, checks or tests then works in the root
(steps.spm-root.outputs.root, else the workspace): SwiftPM records absolute paths.
