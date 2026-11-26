//! `include/cmux_interactivity.h` is cbindgen's output for `src/interactivity.rs`
//! (cbindgen-interactivity.toml), so the header Swift imports cannot drift from the
//! Rust `extern "C"` signatures.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test interactivity_header` rewrites it.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_interactivity_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let header = crate_dir.join("include/cmux_interactivity.h");
    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen-interactivity.toml"))
        .expect("cbindgen-interactivity.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(crate_dir.join("src/interactivity.rs"))
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
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_interactivity.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "cmux-app-ffi/include/cmux_interactivity.h is not cbindgen's output for src/interactivity.rs. Regenerate it \
         with `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test interactivity_header` (cmux-tui/crates/cmux-app-ffi) \
         and commit it; bump the ABI version if a type or function changed.\n{diff}"
    );
}
