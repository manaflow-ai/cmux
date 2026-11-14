//! `cmux-daemon-launch-core/include/cmux_daemon_launch.h` is cbindgen's
//! output for that crate's `src/ffi.rs` (its cbindgen.toml), so the header
//! Swift imports (module CCmuxDaemonLaunchFFI) cannot drift from the Rust
//! `extern "C"` signatures. Here, not in that crate, so cbindgen stays out of
//! the cmux-tui workspace's lock file.
//! `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test daemon_launch_header` rewrites it.

use std::path::Path;
use std::process::Command;

#[test]
fn committed_daemon_launch_header_is_cbindgen_output() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../cmux-daemon-launch-core");
    let header = crate_dir.join("include/cmux_daemon_launch.h");
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
    let fresh = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cmux_daemon_launch.h");
    std::fs::write(&fresh, &generated).expect("write the generated header");
    let diff = Command::new("diff")
        .arg("-u")
        .arg(&header)
        .arg(&fresh)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| String::from_utf8_lossy(&generated).into_owned());
    panic!(
        "cmux-daemon-launch-core/include/cmux_daemon_launch.h is not cbindgen's output for src/ffi.rs. \
         Regenerate it with `CMUX_APP_FFI_HEADER_BLESS=1 cargo test --test daemon_launch_header` \
         (cmux-tui/crates/cmux-app-ffi) and commit it; bump CMUX_DAEMON_LAUNCH_ABI_VERSION if a type or \
         function changed.\n{diff}"
    );
}
