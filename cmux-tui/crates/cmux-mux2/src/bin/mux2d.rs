//! macOS only for now (kqueue, posix_spawn PTY setup); see GOAL.md.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

#[cfg(target_os = "macos")]
#[path = "../macos/mux2d.rs"]
mod imp;

#[cfg(target_os = "macos")]
fn main() {
    imp::main();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("mux2d: macOS only for now");
    std::process::exit(2);
}
