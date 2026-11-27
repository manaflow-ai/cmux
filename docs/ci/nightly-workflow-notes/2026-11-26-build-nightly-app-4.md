# 2026-11-26-build-nightly-app-4

Above `- name: Restore the acpmux and OptChat Chief dependency builds (cmux-next)` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

The cmux-next Rust helpers below (acpmux, the OptChat Chief) compiled
every dependency from scratch on each nightly: about 150 s of the
serial build path (2026-10-09). Their target dirs keep the dependency
builds between nightly-next runs; cargo still rebuilds what changed.
