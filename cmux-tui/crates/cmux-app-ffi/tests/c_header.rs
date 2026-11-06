//! `include/cmux_motion_ffi.h` is cbindgen's output for this crate
//! (cbindgen.toml), and cmux-conversation's `include/cmux_conversation_ffi.h`
//! is its output for that crate's `src/ffi.rs` (cbindgen-conversation.toml), so the header Swift imports cannot drift from the Rust
//! `extern "C"` signatures and `#[repr(C)]` layouts. A drift is silent UB that
//! no Swift test sees; here it fails with the diff.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test c_header` rewrites the headers.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let header = crate_dir.join("include/cmux_motion_ffi.h");
    let config =
        cbindgen::Config::from_file(crate_dir.join("cbindgen.toml")).expect("cbindgen.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_crate(crate_dir)
        .generate()
        .expect("cbindgen generates the header")
        .write(&mut generated);
    // The ABI has no constants: cbindgen copies a reachable struct's
    // associated consts as macros (HoverRect::NULL's `f64_INFINITY` is not C),
    // so a new one needs `cbindgen:ignore`.
    let defines: Vec<&str> = std::str::from_utf8(&generated)
        .expect("utf-8 header")
        .lines()
        .filter(|l| l.starts_with("#define") && *l != "#define CMUX_MOTION_FFI_H")
        .collect();
    assert!(defines.is_empty(), "unexpected macros in the header: {defines:?}");

    check(&header, &generated, "src/motion.rs");
}

#[test]
fn conversation_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let conversation = crate_dir.join("../cmux-conversation");
    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen-conversation.toml"))
        .expect("cbindgen-conversation.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(conversation.join("src/ffi.rs"))
        .generate()
        .expect("cbindgen generates the header")
        .write(&mut generated);
    check(
        &conversation.join("include/cmux_conversation_ffi.h"),
        &generated,
        "cmux-conversation src/ffi.rs",
    );
}

/// Fails with the diff when `header` is not `generated` (or rewrites it
/// under `CMUX_APP_FFI_HEADER_BLESS`).
fn check(header: &Path, generated: &[u8], abi_version_in: &str) {
    let name = header.file_name().and_then(|n| n.to_str()).expect("header name");
    if std::env::var_os("CMUX_APP_FFI_HEADER_BLESS").is_some() {
        std::fs::write(header, generated).expect("write the header");
        return;
    }
    let committed = std::fs::read(header).expect("read the header");
    if committed == generated {
        return;
    }
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::write(&fresh, generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(generated).into_owned());
    panic!(
        "{name} is not cbindgen's output for the Rust C ABI. Regenerate it with \
         `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test c_header` (cmux-tui/crates/cmux-app-ffi) \
         and commit it; bump ABI_VERSION in {abi_version_in} if a type or function changed.\n{diff}"
    );
}
