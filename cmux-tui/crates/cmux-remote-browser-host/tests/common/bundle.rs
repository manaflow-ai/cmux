//! The bundled host app for the macOS tests that run the real CEF host (CEF
//! needs its helper apps beside its framework).

use std::path::{Path, PathBuf};
use std::process::Command;

/// Bundles this build's host binary with the CEF framework of `CEF_PATH`
/// into `dir` and returns the host executable inside the app.
///
/// The fleet's CEF cache is read-only, and `bundle-remote-browser-host.sh`
/// re-signs the framework copy it makes, so it gets a writable copy of the
/// framework first. The script runs with `bash -x`: a failure shows the line
/// that failed (its codesign calls are silent).
pub fn bundle(dir: &Path) -> PathBuf {
    let cef = PathBuf::from(std::env::var("CEF_PATH").expect("CEF_PATH (the fleet build sets it)"));
    let cef = if cef.join("Release").is_dir() { cef.join("Release") } else { cef };
    let fw = "Chromium Embedded Framework.framework";
    let writable = dir.join("cef");
    let _ = std::fs::remove_dir_all(&writable);
    std::fs::create_dir_all(&writable).unwrap();
    let copied = Command::new("/bin/cp").arg("-R").arg(cef.join(fw)).arg(&writable).status();
    assert!(copied.is_ok_and(|s| s.success()), "copy {fw} from {cef:?}");
    let chmod = Command::new("/bin/chmod").arg("-R").arg("u+w").arg(&writable).status();
    assert!(chmod.is_ok_and(|s| s.success()), "chmod the framework copy");
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let app = dir.join("cmux-remote-browser-host.app");
    let out = Command::new("/bin/bash")
        .arg("-x")
        .arg(repo.join("scripts/cmux-next/bundle-remote-browser-host.sh"))
        .arg(env!("CARGO_BIN_EXE_cmux-remote-browser-host"))
        .arg(&writable)
        .arg(&app)
        .output()
        .expect("bundle");
    assert!(
        out.status.success(),
        "bundle-remote-browser-host.sh failed: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let _ = std::fs::remove_dir_all(&writable);
    app.join("Contents/MacOS/cmux-remote-browser-host")
}
