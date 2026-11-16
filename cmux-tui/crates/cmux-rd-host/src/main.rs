//! The `cmux-rd` executable: the host engine's subcommands (src/lib.rs, [`cmux_rd_host::run_cli`]).
//! On a Mac it is also the executable of the Screen Sharing helper app
//! (plans/cmux-next/screen-sharing-helper.md), which macOS may open by itself.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if std::env::current_exe()
        .is_ok_and(|executable| cmux_rd_host::is_launch_services_open(&args, &executable))
    {
        return;
    }
    std::process::exit(cmux_rd_host::run_cli(&args));
}
