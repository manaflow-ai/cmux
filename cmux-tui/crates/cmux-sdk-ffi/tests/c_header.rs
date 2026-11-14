//! `include/cmux_sdk_ffi.h` is cbindgen's output for this crate
//! (cbindgen.toml), so the header Swift imports cannot drift from the Rust
//! `extern "C"` signatures, and it compiles as strict C11.
//! `CMUX_SDK_FFI_HEADER_BLESS=1 cargo test --test c_header` rewrites it.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let header = crate_dir.join("include/cmux_sdk_ffi.h");
    let config =
        cbindgen::Config::from_file(crate_dir.join("cbindgen.toml")).expect("cbindgen.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_crate(crate_dir)
        .generate()
        .expect("cbindgen generates the header")
        .write(&mut generated);
    if std::env::var_os("CMUX_SDK_FFI_HEADER_BLESS").is_some() {
        std::fs::write(&header, &generated).expect("write the header");
        return;
    }
    let committed = std::fs::read(&header).expect("read the header");
    if committed == generated {
        return;
    }
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_sdk_ffi.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "include/cmux_sdk_ffi.h is not cbindgen's output for the Rust C ABI. Regenerate it with \
         `CMUX_SDK_FFI_HEADER_BLESS=1 cargo test --test c_header` (cmux-tui/crates/cmux-sdk-ffi) \
         and commit it; bump ABI_VERSION in src/lib.rs if a type or function changed.\n{diff}"
    );
}

#[test]
fn header_compiles_as_strict_c() {
    let header = Path::new(env!("CARGO_MANIFEST_DIR")).join("include/cmux_sdk_ffi.h");
    let output = Command::new("cc")
        .args(["-x", "c", "-std=c11", "-fsyntax-only", "-Wall", "-Wextra", "-Werror"])
        .arg(&header)
        .output()
        .expect("run cc");
    assert!(
        output.status.success(),
        "include/cmux_sdk_ffi.h does not compile as C:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
