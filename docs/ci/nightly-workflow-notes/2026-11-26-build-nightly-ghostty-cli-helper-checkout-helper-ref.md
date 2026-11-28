# nightly.yml: job `build-nightly-ghostty-cli-helper`, step "Checkout helper ref"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The helper and the classic ghostty tree take the default Zig (PATH,
CMUX_ZIG); the source archive's libghostty-vt tree (ghostty-next,
0.17.0) takes CMUX_VT_ZIG, a local install beside it.
