# nightly.yml: job `refresh-compilation-cache`, step "Install compilation dependencies"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The default Zig (PATH, CMUX_ZIG) is the classic ghostty tree's; the
acpmux build's libghostty-vt (ghostty-vt-sys, ghostty-next) takes
CMUX_VT_ZIG, a local install beside it, as the helper job does.
