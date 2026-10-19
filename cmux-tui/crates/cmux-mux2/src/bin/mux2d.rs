//! The mux2 server: kqueue on macOS, epoll on Linux, an IO completion port
//! on Windows. See GOAL.md.

#[cfg(unix)]
#[path = "../unix/mux2d.rs"]
mod imp;

#[cfg(windows)]
#[path = "../windows/mux2d.rs"]
mod imp;

fn main() {
    imp::main();
}
