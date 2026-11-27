# 2026-11-27-build-nightly-ghostty-cli-helper-1

Above `- &select-xcode-sdk-unless-resumed` (job `build-nightly-ghostty-cli-helper`) in `.github/workflows/nightly.yml`.

*select-xcode-sdk with the `if:` of this job's build steps (a resumed run builds nothing).
Zig only: no Xcode is selected here, so this is the SDK of the host's default Xcode.
