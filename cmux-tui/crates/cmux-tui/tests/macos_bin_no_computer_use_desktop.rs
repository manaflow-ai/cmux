//! The macOS `cmux-tui` binary links cmux Computer Use's engine only, never
//! its `desktop` feature. The Linux pool cross-links the macOS binary with an
//! SDK that has no AppKit or Accessibility symbols, and on macOS the worker
//! runs in the Screen Sharing helper (`cmux-screen-sharing
//! __computer-use-worker`), not in this binary. #48865 gave cmux-rd-host, which
//! this binary links for `cmux rd`, a plain dependency on the engine with
//! `desktop`: every pool app build of feat-cmux-next then failed
//! (2026-11-21, `ld64.lld: undefined symbol: AXObserverRemoveNotification`).
//!
//! The check asks cargo how it resolves the binary's features for the macOS
//! target, so it runs on any host.

use std::process::Command;

#[test]
fn the_macos_binary_resolves_computer_use_without_its_desktop_feature() {
    let manifest = concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml");
    let out = Command::new(env!("CARGO"))
        .args(["tree", "--manifest-path", manifest, "-p", "cmux-tui", "--target"])
        .args(["aarch64-apple-darwin", "-e", "features", "--prefix", "none", "--locked"])
        .output()
        .expect("cargo tree runs");
    let tree = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "cargo tree failed: {}", String::from_utf8_lossy(&out.stderr));
    assert!(
        tree.lines().any(|l| l.starts_with("cmux-computer-use v")),
        "cmux-computer-use is not in the macOS tree:\n{tree}"
    );
    let desktop: Vec<&str> =
        tree.lines().filter(|l| l.starts_with("cmux-computer-use feature \"desktop\"")).collect();
    assert!(
        desktop.is_empty(),
        "the macOS cmux-tui binary turns on cmux-computer-use's desktop feature: {desktop:?}"
    );
}
