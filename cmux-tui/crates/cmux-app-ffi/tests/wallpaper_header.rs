//! `include/cmux_wallpaper_ffi.h` is cbindgen's output for `src/wallpaper.rs`
//! (cbindgen-wallpaper.toml), so the header Swift imports cannot drift from
//! the Rust `extern "C"` signatures and `#[repr(C)]` layouts.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test wallpaper_header` rewrites it.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_wallpaper_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let header = crate_dir.join("include/cmux_wallpaper_ffi.h");
    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen-wallpaper.toml"))
        .expect("cbindgen-wallpaper.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(crate_dir.join("src/wallpaper.rs"))
        .generate()
        .expect("cbindgen generates the header")
        .write(&mut generated);
    let text = std::str::from_utf8(&generated).expect("utf-8 header");
    for name in [
        "cmux_wallpaper_abi_version",
        "cmux_wallpaper_compile",
        "cmux_wallpaper_schedule",
        "cmux_wallpaper_frame_pack",
        "cmux_wallpaper_pointer_update",
    ] {
        assert!(text.contains(name), "{name} is missing from the header");
    }
    if std::env::var_os("CMUX_APP_FFI_HEADER_BLESS").is_some() {
        std::fs::write(&header, &generated).expect("write the header");
        return;
    }
    let committed = std::fs::read(&header).unwrap_or_default();
    if committed == generated {
        return;
    }
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_wallpaper_ffi.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "include/cmux_wallpaper_ffi.h is not cbindgen's output for src/wallpaper.rs. Regenerate it with \
         `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test wallpaper_header` (cmux-tui/crates/cmux-app-ffi) \
         and commit it; bump ABI_VERSION in src/wallpaper.rs if a type or function changed.\n{diff}"
    );
}
