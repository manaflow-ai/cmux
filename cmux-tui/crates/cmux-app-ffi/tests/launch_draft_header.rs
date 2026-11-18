//! `cmux-launch-draft/include/cmux_launch_draft.h` is cbindgen's output for
//! that crate's `src/ffi.rs` (its cbindgen.toml), so the header Swift imports
//! (module CCmuxLaunchDraftFFI) cannot drift from the Rust `extern "C"`
//! signatures; it compiles as C11, and the app library exports every function
//! it declares. Here, not in that crate, so cbindgen stays out of its
//! dependencies.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test launch_draft_header` rewrites it.

use std::path::Path;
use std::process::Command;

const FUNCTIONS: &[&str] = &[
    "cmux_launch_draft_abi_version",
    "cmux_launch_draft_new",
    "cmux_launch_draft_free",
    "cmux_launch_draft_string_free",
    "cmux_launch_draft_hold",
    "cmux_launch_draft_resolve",
    "cmux_launch_draft_next",
    "cmux_launch_draft_delivered",
    "cmux_launch_draft_held",
    "cmux_launch_draft_cancel",
    "cmux_launch_draft_is_cancelled",
    "cmux_launch_draft_text_of",
    "cmux_launch_draft_chief",
    "cmux_launch_draft_append",
    "cmux_launch_draft_save_for_quit",
    "cmux_launch_draft_park",
    "cmux_launch_draft_decode",
];

#[test]
fn committed_launch_draft_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../cmux-launch-draft");
    let header = crate_dir.join("include/cmux_launch_draft.h");
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
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_launch_draft.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "cmux-launch-draft/include/cmux_launch_draft.h is not cbindgen's output for src/ffi.rs. \
         Regenerate it with `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test launch_draft_header` \
         (cmux-tui/crates/cmux-app-ffi) and commit it; bump CMUX_LAUNCH_DRAFT_ABI_VERSION if a \
         constant or function changed.\n{diff}"
    );
}

#[test]
fn launch_draft_header_compiles_and_is_exported() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let include = crate_dir.join("../cmux-launch-draft/include");
    let temporary = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let source = temporary.join("launch_draft_header.c");
    let object = temporary.join("launch_draft_header.o");
    let mut c = String::from("#include \"cmux_launch_draft.h\"\n");
    // Each declared function's address: a missing or renamed one fails to compile.
    for name in FUNCTIONS {
        c.push_str(&format!("void *ref_{name}(void) {{ return (void *)&{name}; }}\n"));
    }
    std::fs::write(&source, c).unwrap();
    let output = Command::new("cc")
        .arg("-std=c11")
        .arg("-Wall")
        .arg("-Werror")
        .arg("-Wno-pedantic")
        .arg("-I")
        .arg(&include)
        .arg("-c")
        .arg(&source)
        .arg("-o")
        .arg(&object)
        .output()
        .unwrap();
    assert!(output.status.success(), "C header: {}", String::from_utf8_lossy(&output.stderr));
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
