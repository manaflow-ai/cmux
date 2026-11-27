# 2026-11-27-build-nightly-app-13

Above `- name: Restore pinned Node 24.22.1 from the CI cache bucket` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).
