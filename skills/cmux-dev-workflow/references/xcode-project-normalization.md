# Xcode Project Normalization

The pin (`.xcode-version`, `objectVersion = 60`), the pre-commit hook, and the CI guard are described in [../SKILL.md](../SKILL.md).

## Bumping the Xcode pin

1. Edit `.xcode-version`. It holds the Xcode major only; CI refuses any Xcode below it.
2. Open `cmux.xcodeproj` in the new Xcode so it rewrites `objectVersion`.
3. Add a case in `scripts/check-pbxproj.sh` mapping the new Xcode major to the `objectVersion` that major writes.
4. Run `scripts/normalize-pbxproj.py`.
5. Point every line of `scripts/ci/xcode-pins.txt` at an Xcode of the new major that the runner pools carry, and move the `CMUX_CI_XCODE_APP_MACOS_*` variables with them.

Do not change `objectVersion` opportunistically as part of unrelated project edits.
