//! The `cmux-rd` executable: the host engine's subcommands (src/lib.rs, [`cmux_rd_host::run_cli`]).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(cmux_rd_host::run_cli(&args));
}
