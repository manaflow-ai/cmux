# refresh-compilation-cache: Install compilation dependencies

Where: the `refresh-compilation-cache` job in `.github/workflows/nightly.yml`, above `- name: Install compilation dependencies`.

The default Zig (PATH, CMUX_ZIG) is the classic ghostty tree's; the
acpmux build's libghostty-vt (ghostty-vt-sys, ghostty-next) takes
CMUX_VT_ZIG, a local install beside it, as the helper job does.
