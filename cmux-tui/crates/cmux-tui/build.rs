//! Link flags of the cmux-tui binaries, and the browser names the client
//! knows.

use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    // The macOS terminal host (src/bin/cmux-tui-host.rs) links the crates of
    // the terminal-host runtime, whose dependency graph names frameworks
    // (CoreFoundation, Security, CFNetwork, ...) that the host never calls.
    // Every linked framework is loaded into every terminal host and pulls in
    // its own dependencies; drop the ones no kept symbol references.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg-bin=cmux-tui-host=-Wl,-dead_strip_dylibs");
        // The release cmux-tui binary (the app's bin/cmux) exports no symbols. Thin LTO
        // leaves every Rust function global, so the linker wrote an export trie of 62,020
        // names (2.6 MB of nightly 4413904924501's bin/cmux) that nothing reads: no image
        // loaded into it looks a symbol up in it (its dlsym calls all name system
        // symbols), and it loads no plugins. The functions become local symbols;
        // strip-release-bundle.sh keeps their names in Resources/cmux-tui-symbols.bin,
        // as the app's executable (also -no_exported_symbols) keeps its own in
        // cmux-symbols.bin. Apple's ld (the fast nightly client) and ld64.lld (the Linux
        // cross build, scripts/ci/macos-cross.sh) both take the flag. Debug builds keep
        // their exports: `dx` hot-patching (cmux-tui-hotpatch, a separate binary) and
        // debuggers there resolve through them.
        if std::env::var("PROFILE").as_deref() == Ok("release") {
            // measurement control: flag off
        }
    }
    browser_names();
}

/// `cmux setup browser-import` matches a browser by its registry id or
/// product name, and reads nothing else of the app's browser registry. Only
/// those two go into the binary (`$OUT_DIR/browser_names.rs`): the registry's
/// data directories, file names and Keychain service names stay with the app.
/// A build with the browser import compiled out (an emptied registry, or
/// CMUX_NO_BROWSER_DATA_IMPORT set for cargo) knows no browser names, as the
/// app knows none.
fn browser_names() {
    let manifest =
        PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let registry = manifest.join(
        "../../../Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json",
    );
    println!("cargo:rerun-if-changed={}", registry.display());
    println!("cargo:rerun-if-env-changed=CMUX_NO_BROWSER_DATA_IMPORT");
    let compiled_out =
        std::env::var_os("CMUX_NO_BROWSER_DATA_IMPORT").is_some_and(|value| !value.is_empty());
    let text = std::fs::read_to_string(&registry)
        .unwrap_or_else(|error| panic!("read {}: {error}", registry.display()));
    let parsed: serde_json::Value = serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("parse {}: {error}", registry.display()));
    let mut rows = String::new();
    if !compiled_out {
        for row in parsed["browsers"].as_array().into_iter().flatten() {
            let Some(id) = row["id"].as_str() else { continue };
            let name = row["name"].as_str().unwrap_or(id);
            rows.push_str(&format!("    ({id:?}, {name:?}),\n"));
        }
    }
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("browser_names.rs");
    std::fs::write(&out, format!("&[\n{rows}]\n"))
        .unwrap_or_else(|error| panic!("write {}: {error}", out.display()));
}
