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
    browser_names();
    design_view();
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

/// `cmux ext design --show --scene` (Settings > Design system) draws the SDK's DesignSystemView
/// from `src/cli/ext/design_view/src/main.ts`, packed into one script by the packer every app is
/// built with (`cmux-app-host/tools/pack.ts`). The packed script is build output, so it is written
/// to `$OUT_DIR/design_view/dist/main.js`, never committed (scripts/ci/generated_files_guard.py).
/// It takes bun (`CMUX_BUN`, else PATH, else `~/.bun/bin/bun`); a build with no bun writes an
/// empty script and warns, and that build's `--scene` says it has no view.
fn design_view() {
    let manifest =
        PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let crates = manifest.join("..");
    let entry = manifest.join("src/cli/ext/design_view/src/main.ts");
    let packer = crates.join("cmux-app-host/tools/pack.ts");
    let sdk_dir = crates.join("cmux-extension-sdk/typescript/src");
    let mut inputs = vec![
        entry.clone(),
        packer.clone(),
        crates.join("cmux-app-host/schema/v2/events.json"),
        crates.join("cmux-app-host/generated/scopes.json"),
    ];
    // The SDK's own sources only: its `generated/` folder is rewritten by every SDK build.
    if let Ok(dir) = std::fs::read_dir(&sdk_dir) {
        inputs.extend(
            dir.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "ts")),
        );
    }
    for input in &inputs {
        println!("cargo:rerun-if-changed={}", input.display());
    }
    println!("cargo:rerun-if-env-changed=CMUX_BUN");

    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("design_view");
    let src = out.join("src");
    std::fs::create_dir_all(&src)
        .unwrap_or_else(|error| panic!("create {}: {error}", src.display()));
    std::fs::copy(&entry, src.join("main.ts"))
        .unwrap_or_else(|error| panic!("copy {}: {error}", entry.display()));
    let dist = out.join("dist/main.js");
    let Some(bun) = find_bun() else {
        println!(
            "cargo:warning=bun not found (CMUX_BUN, PATH, ~/.bun/bin): this build's \
             `cmux ext design --show --scene` has no design view"
        );
        std::fs::create_dir_all(out.join("dist")).expect("create dist");
        std::fs::write(&dist, "").expect("write the empty design view");
        return;
    };
    // The packer's SDK fallback resolves to this path, which bun takes only absolute.
    let sdk = sdk_dir.join("index.ts");
    let sdk = sdk.canonicalize().unwrap_or_else(|error| panic!("{}: {error}", sdk.display()));
    let ran = std::process::Command::new(&bun)
        .arg(&packer)
        .arg(&out)
        .env("CMUX_EXTENSION_SDK", &sdk)
        .output()
        .unwrap_or_else(|error| panic!("run {}: {error}", bun.display()));
    if !ran.status.success() {
        panic!(
            "packing {} failed:\n{}{}",
            entry.display(),
            String::from_utf8_lossy(&ran.stdout),
            String::from_utf8_lossy(&ran.stderr)
        );
    }
}

fn find_bun() -> Option<PathBuf> {
    if let Some(bun) = std::env::var_os("CMUX_BUN").map(PathBuf::from) {
        return bun.is_file().then_some(bun);
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .map(|dir| dir.join("bun"))
        .chain(std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".bun/bin/bun")))
        .find(|bun| bun.is_file())
}
