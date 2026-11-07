//! `cmux-daemon-conn-core/include/cmux_daemon_conn.h` is cbindgen's output
//! for that crate's C ABI (its cbindgen.toml; src/ffi.rs, src/retry.rs and
//! src/heartbeat.rs), so the header Swift imports (`CCmuxDaemonConnFFI`)
//! cannot drift from the Rust `extern "C"` signatures and `#[repr(C)]`
//! layouts. It runs here, where cbindgen is a dev-dependency, so the cmux-tui
//! workspace lock does not gain cbindgen.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test daemon_conn_header` rewrites it.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_daemon_conn_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../cmux-daemon-conn-core");
    let header = crate_dir.join("include/cmux_daemon_conn.h");
    let config =
        cbindgen::Config::from_file(crate_dir.join("cbindgen.toml")).expect("cbindgen.toml");
    let mut generated = Vec::new();
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(crate_dir.join("src/retry.rs"))
        .with_src(crate_dir.join("src/heartbeat.rs"))
        .with_src(crate_dir.join("src/ffi.rs"))
        .generate()
        .expect("cbindgen generates the header")
        .write(&mut generated);

    if std::env::var_os("CMUX_APP_FFI_HEADER_BLESS").is_some() {
        std::fs::write(&header, &generated).expect("write the header");
        return;
    }
    let committed = std::fs::read(&header).expect("read the header");
    if committed == generated {
        return;
    }
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_daemon_conn.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "cmux-daemon-conn-core/include/cmux_daemon_conn.h is not cbindgen's output for its C ABI. \
         Regenerate it with `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test daemon_conn_header` \
         (cmux-tui/crates/cmux-app-ffi) and commit it; bump ABI_VERSION in src/ffi.rs if a type or \
         function changed.\n{diff}"
    );
}
