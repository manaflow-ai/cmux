//! Link flags of the cmux-tui binaries.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    // The macOS terminal host (src/bin/cmux-tui-host.rs) links the crates of
    // the terminal-host runtime, whose dependency graph names frameworks
    // (CoreFoundation, Security, CFNetwork, ...) that the host never calls.
    // Every linked framework is loaded into every terminal host and pulls in
    // its own dependencies; drop the ones no kept symbol references.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg-bin=cmux-tui-host=-Wl,-dead_strip_dylibs");
    }
}
