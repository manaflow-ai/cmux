//! The mount helper as a small binary of its own (`cmux-projfs mount …`), the same as
//! `cmux-tui projfs …`; see [`cmux_projfs::helper`].

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(cmux_projfs::helper::run(&args));
}
