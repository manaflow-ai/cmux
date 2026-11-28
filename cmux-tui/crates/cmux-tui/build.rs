//! Link flags of the cmux-tui binaries. The library's build script
//! (crates/cmux-tui-lib/build.rs) writes the browser names the client knows.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    // The macOS terminal host (src/bin/cmux-tui-host.rs) links the crates of
    // the terminal-host runtime, whose dependency graph names frameworks
    // (CoreFoundation, Security, CFNetwork, ...) that the host never calls.
    // Every linked framework is loaded into every terminal host and pulls in
    // its own dependencies; drop the ones no kept symbol references.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg-bin=cmux-tui-host=-Wl,-dead_strip_dylibs");
        // The shipped binaries export nothing: no dylib or plugin looks a symbol
        // up in them (every dlsym here asks for a system symbol). Without this the
        // linker writes an export trie of every global (Rust, QuickJS, ghostty),
        // and the release strip keeps that region even after emptying it: 6.8 MB
        // of bin/cmux's 104.0 MB in NIGHTLY 4487759453601 reached one name. The
        // in-app symbol map (write-app-symbol-map.py) reads the local symbols this
        // leaves, as for the app executable (cmux#20762). cmux-tui-hotpatch keeps
        // its exports for the patcher.
        for bin in ["cmux-tui", "cmux-tui-host", "cmux-tui-hook"] {
            println!("cargo:rustc-link-arg-bin={bin}=-Wl,-no_exported_symbols");
        }
    }
}
