//! The identity of this cmux-tui build: `CMUX_TUI_BUILD_COMMIT` when the
//! build sets it (release and CI builds), otherwise the HEAD commit, plus
//! `-dirty.<hash>` of the uncommitted cmux-tui sources (build.rs).
//!
//! Daemon skew detection and SSH host re-bootstrap compare this value, so a
//! dev build must change it on every source edit. It lives in this leaf crate,
//! not in cmux-remote, because the build script reruns on every edit in the
//! workspace: only this crate and the crates that read it (cmux-tui) recompile,
//! not cmux-remote and everything between it and the binary. Library crates
//! take the value as an argument (`SshBootstrapConfig::defaults`,
//! `pinned_linux_payload`); do not depend on this crate from a library that
//! the binary does not otherwise rebuild on every edit.

#![forbid(unsafe_code)]

/// This build's identity. See the crate documentation.
pub const BUILD_IDENTITY: &str = env!("CMUX_TUI_BUILD_IDENTITY");

/// Unix seconds of the commit this binary was built from (cx-3r9mt): what
/// `remote update-need` orders two builds with the same capabilities by; 0
/// when unknown. A fleet build that reuses a cached binary of the same
/// cmux-tui source tree reports the commit (and time) of the FIRST build of
/// that tree, not the app's commit (hq-25 2026-10-15): the same tree is the
/// same binary, and two trees order by their first build.
pub const BUILD_TIME: u64 = parse_u64(env!("CMUX_TUI_BUILD_TIME"));

const fn parse_u64(text: &str) -> u64 {
    let mut rest = text.as_bytes();
    let mut value: u64 = 0;
    while let [digit, tail @ ..] = rest {
        let digit = *digit;
        if !digit.is_ascii_digit() {
            return 0;
        }
        value = match value.checked_mul(10) {
            Some(scaled) => match scaled.checked_add((digit - b'0') as u64) {
                Some(next) => next,
                None => return 0,
            },
            None => return 0,
        };
        rest = tail;
    }
    value
}
