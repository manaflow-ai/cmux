# build-nightly-ghostty-cli-helper: &x2

Where: the `build-nightly-ghostty-cli-helper` job in `.github/workflows/nightly.yml`, above `- &x2`.

The helper and the classic ghostty tree take the default Zig (PATH,
CMUX_ZIG); the source archive's libghostty-vt tree (ghostty-next,
0.17.0) takes CMUX_VT_ZIG, a local install beside it.
