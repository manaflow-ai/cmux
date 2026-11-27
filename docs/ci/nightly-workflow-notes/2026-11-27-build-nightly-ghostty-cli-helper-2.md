# 2026-11-27-build-nightly-ghostty-cli-helper-2

Above `- &x2` (job `build-nightly-ghostty-cli-helper`) in `.github/workflows/nightly.yml`.

The helper and the classic ghostty tree take the default Zig (PATH,
CMUX_ZIG); the source archive's libghostty-vt tree (ghostty-next,
0.17.0) takes CMUX_VT_ZIG, a local install beside it.
