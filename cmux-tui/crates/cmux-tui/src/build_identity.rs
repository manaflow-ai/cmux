//! This build's identity (`crate::build_identity::identity()` and
//! `BUILD_TIME`), installed by the binary at start.
//!
//! cmux-build-identity's build script reruns on every source edit, and Cargo
//! recompiles every crate that depends on a crate whose build script reran.
//! The library (the cmux-tui-lib package) used to read the constants itself,
//! so every edit anywhere recompiled the whole program, about 11 s
//! (dev-loop-ceiling, cmux#59579's A/B). The cmux-tui binary depends on
//! cmux-build-identity instead and calls [`install`] before
//! [`crate::main`]; the library reads the value through [`identity`] and
//! [`time`]. Builds with no such binary compile the constants in: the Windows
//! DLL (`windows-thin-exe`), `cmux-tui-hotpatch` (`hotpatch`) and the
//! library's unit tests.

use std::sync::OnceLock;

static INSTALLED: OnceLock<(&'static str, u64)> = OnceLock::new();

/// Sets this build's identity and commit time. The binary calls it first; a
/// second call keeps the first value.
pub fn install(identity: &'static str, time: u64) {
    let _ = INSTALLED.set((identity, time));
}

fn installed() -> (&'static str, u64) {
    *INSTALLED.get_or_init(compiled_in)
}

/// This build's identity. See the module documentation.
pub fn identity() -> &'static str {
    installed().0
}

/// Unix seconds of the commit this binary was built from; 0 when unknown.
pub fn time() -> u64 {
    installed().1
}

#[cfg(any(test, feature = "hotpatch", feature = "windows-thin-exe"))]
fn compiled_in() -> (&'static str, u64) {
    (crate::build_identity::identity(), crate::build_identity::time())
}

/// A binary that links the library calls [`install`] before anything reads
/// the identity; reading it first is that binary's bug. Daemon skew checks
/// and SSH re-bootstrap compare this value, so a guessed one would restart
/// or reinstall forever: stop instead.
#[cfg(not(any(test, feature = "hotpatch", feature = "windows-thin-exe")))]
fn compiled_in() -> (&'static str, u64) {
    panic!("cmux-tui: the binary did not install the build identity (build_identity::install)")
}
