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
