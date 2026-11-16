//! `cmux-app-host`: spawned by the daemon's app supervisor with fd 3 as its
//! channel. `--profile script` runs a script session (the script limits);
//! `--sandbox-self-test <path>` exists for the integration tests. The program
//! is [`cmux_app_host::entry::run`].

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(cmux_app_host::entry::run(&args));
}
