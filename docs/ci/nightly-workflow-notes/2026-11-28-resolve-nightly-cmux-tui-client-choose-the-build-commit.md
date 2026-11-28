# 2026-11-28-resolve-nightly-cmux-tui-client-choose-the-build-commit

Where: `.github/workflows/nightly.yml`, job `resolve-nightly-cmux-tui-client`, step "Choose the build commit": above `- name: Pack the build source for later jobs`.

The build commit's source once per run, from this mirror-served checkout: later jobs unpack it instead of fetching from github.com (scripts/ci/nightly-source.sh).
