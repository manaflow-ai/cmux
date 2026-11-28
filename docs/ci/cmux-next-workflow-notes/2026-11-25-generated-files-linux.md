# cmux-next.yml generated-files-linux: the Linux generated files check

Stood above the `generated-files-linux` job ("cmux-next generated files"), and is the why of
`scripts/ci/cmux-next-steps/generated-files-linux.sh`.

Why: docs/ci/cmux-next-workflow-notes.md#note-59
Leo, 2026-11-25: "if like... it works on linux and is at least as fast if not faster, then we ought to just go
ahead. especially if we use freestyle vms." The generated files checks run on the fleet's Linux pool: the action
exports from the Rust catalog at the app-ffi-pin.json commit (what the Swift export reads), the settings exports and
links.json from their sources, judged by the same scripts as the Mac job (judge-action-exports.sh,
check-settings-exports.sh) with their export commands swapped for the Linux ones. The Mac job below runs only when
this one gives no verdict: an exporter that cannot run here, a parity mismatch with a Swift-made export kept in R2
(generated-parity-linux.sh), or vars.CI_GENERATED_FILES_LINUX == '0'. It logs itself as the fallback.
