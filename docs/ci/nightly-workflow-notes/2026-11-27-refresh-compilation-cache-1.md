# 2026-11-27-refresh-compilation-cache-1

Above `- name: Install compilation dependencies` (job `refresh-compilation-cache`) in `.github/workflows/nightly.yml`.

The default Zig (PATH, CMUX_ZIG) is the classic ghostty tree's; the
acpmux build's libghostty-vt (ghostty-vt-sys, ghostty-next) takes
CMUX_VT_ZIG, a local install beside it, as the helper job does.
