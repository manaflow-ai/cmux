//! macOS only for now (kqueue, posix_spawn PTY setup); see GOAL.md.

#[cfg(target_os = "macos")]
#[path = "../macos/mux2_ctty_probe.rs"]
mod imp;

#[cfg(target_os = "macos")]
fn main() {
    imp::main();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("mux2-ctty-probe: macOS only for now");
    std::process::exit(2);
}
