# Notice to PL-acpmux: the ACPMUX_BIN wrapper's folder, path and temporary files (2026-11-09)

F1, F2, F5 and F7 of #39020 (owner W5-S). `cli_caller.rs`: `install_wrapper` makes and checks
`<home>/bin` with `config::private_state_dir` (refused when another user can write it or an
ancestor, or the home is gone). `wrapper_path` is absolute, so a relative `ACPMUX_HOME` gives
agents an absolute `ACPMUX_BIN`. A write removes `.acpmux.<pid>.<n>.tmp` files whose writer is
gone (`ESRCH`). New test (cmux-tui `acpmux_bin_cmux_layout.rs`): `"$ACPMUX_BIN"` with only the
agent's own environment reaches the daemon that started it.
