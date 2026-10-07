//! Standalone `cmux-tasks` until the `cmux` binary mounts `cmux task`.

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    cmux_tasks::cli::run(&args)
}
