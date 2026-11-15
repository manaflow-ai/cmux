# Notice to PL-acpmux: the Chief reads only a private ACPMUX_BIN wrapper (2026-11-09)

Review of #39552 (owner W5-S). `optchat-chief` `acpmux_wrapper::target` opens the file once
(non-blocking), checks on that handle that it is a regular file this user owns with no group or
other write bit (acpmux writes it 0700), and reads at most 4 KiB + 1. Any other file names no
daemon, so the peer check stays on the file itself.
