//! Unix only for now (kqueue on macOS, epoll on Linux); Windows comes next. See GOAL.md.

#[cfg(unix)]
#[path = "../unix/mux2d.rs"]
mod imp;

#[cfg(unix)]
fn main() {
    imp::main();
}

#[cfg(not(unix))]
fn main() {
    eprintln!("mux2d: Unix only for now");
    std::process::exit(2);
}
