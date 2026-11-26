# build-nightly-ghostty-cli-helper: &select-xcode-sdk-unless-resumed

Where: the `build-nightly-ghostty-cli-helper` job in `.github/workflows/nightly.yml`, above `- &select-xcode-sdk-unless-resumed`.

*select-xcode-sdk with the `if:` of this job's build steps (a resumed run builds nothing).
Zig only: no Xcode is selected here, so this is the SDK of the host's default Xcode.
