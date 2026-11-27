//! `cmux-app-ffi/include/cmux_background_ready.h` is cbindgen's
//! output for that crate's `src/ffi.rs` (its cbindgen.toml), so the header
//! Swift imports (module CCmuxBackgroundReadyFFI) cannot drift from the Rust
//! `extern "C"` signatures, and the packaged library exports every function it
//! declares. `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test background_ready_header`
//! rewrites it.

use std::path::Path;
use std::process::Command;

const FUNCTIONS: [&str; 7] = [
    "cmux_background_ready_mode_parse",
    "cmux_background_ready_on_quit",
    "cmux_background_ready_hidden_plan",
    "cmux_background_ready_registers_login_item",
    "cmux_background_ready_at_launch",
    "cmux_background_ready_exits_for_update",
    "cmux_background_ready_starts_chromium_warmup",
];

#[test]
fn committed_background_ready_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../cmux-background-ready");
    let header = Path::new(env!("CARGO_MANIFEST_DIR")).join("include/cmux_background_ready.h");
    let config =
        cbindgen::Config::from_file(crate_dir.join("cbindgen.toml")).expect("cbindgen.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(crate_dir.join("src/ffi.rs"))
        .generate()
        .expect("cbindgen generates the header")
        .write(&mut generated);
    if std::env::var_os("CMUX_APP_FFI_HEADER_BLESS").is_some() {
        std::fs::write(&header, &generated).expect("write the header");
        return;
    }
    let committed = std::fs::read(&header).unwrap_or_default();
    if committed == generated {
        return;
    }
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_background_ready.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "cmux-app-ffi/include/cmux_background_ready.h is not cbindgen's output for src/ffi.rs. \
         Regenerate it with `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test background_ready_header` \
         (cmux-tui/crates/cmux-app-ffi) and commit it.\n{diff}"
    );
}

#[test]
fn packaged_library_exports_every_background_ready_function() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let exports = Command::new("bash")
        .arg(crate_dir.join("../../../scripts/cmux-next/build-app-ffi.sh"))
        .arg("--list-exports")
        .output()
        .unwrap();
    assert!(exports.status.success(), "{}", String::from_utf8_lossy(&exports.stderr));
    let exports = String::from_utf8(exports.stdout).unwrap();
    for name in FUNCTIONS {
        let symbol = format!("_{name}");
        assert!(exports.lines().any(|line| line == symbol), "missing packaged symbol {symbol}");
    }
}
