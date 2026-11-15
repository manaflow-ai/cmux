//! `acpmux-client/include/acpmux_client.h` is cbindgen's
//! output for that crate's `src/ffi.rs` (its cbindgen.toml), so the header
//! Swift imports (module CAcpmuxClientFFI) cannot drift from the Rust
//! `extern "C"` signatures. Here, not in that crate, so cbindgen stays out of
//! the cmux-tui workspace's lock file.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test acpmux_client_header` rewrites it.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_acpmux_client_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../acpmux-client");
    let header = crate_dir.join("include/acpmux_client.h");
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
        std::fs::create_dir_all(crate_dir.join("include")).expect("create header directory");
        std::fs::write(&header, &generated).expect("write the header");
        return;
    }
    let committed = std::fs::read(&header).unwrap_or_default();
    if committed == generated {
        return;
    }
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("acpmux_client.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "acpmux-client/include/acpmux_client.h is not cbindgen's output for src/ffi.rs. \
         Regenerate it with `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test acpmux_client_header` \
         (cmux-tui/crates/cmux-app-ffi) and commit it; bump ACPMUX_CLIENT_ABI_VERSION if a type or \
         function changed.\n{diff}"
    );
}
