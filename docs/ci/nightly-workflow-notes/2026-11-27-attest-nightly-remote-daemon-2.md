# 2026-11-27-attest-nightly-remote-daemon-2

Above `resolve-nightly-cmux-tui-client:` (job `attest-nightly-remote-daemon`) in `.github/workflows/nightly.yml`.

Runs beside build-nightly-app. Deepening the shallow clone to find the
newest published cmux-tui commit took 1.5 to 11 minutes after the Xcode
compile (runs 36044415287, 36051668491); here it overlaps the compile.
