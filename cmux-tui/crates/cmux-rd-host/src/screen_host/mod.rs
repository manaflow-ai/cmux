//! The device hub client a desktop host shares across operating systems: `cmux-rd linux-host`
//! (src/linux_host/) and `cmux-rd windows-host` (src/windows_host.rs) both register this
//! machine as a screen host of the account (docs/device-hub/PROTOCOL.md), with a device key
//! in private files, the hub's HTTPS and WebSocket, and the same local consent model.
//!
//!   b64       base64 (standard and url-safe) without a crate
//!   consent   this machine's own consent file and the pending viewer requests
//!   hub       device-signed hub calls, the account session and its renewal
//!   identity  the device key and account, kept in this user's private files
//!   net       HTTPS and WebSocket over rustls with the platform trust store

// Windows serves no session yet (docs/device-hub/windows-host.md, step 4): the session-side
// calls (signing a session key, the session socket, verifying a viewer) are Linux's until then.
#![cfg_attr(windows, allow(dead_code))]

pub mod b64;
pub mod consent;
pub mod hub;
pub mod identity;
pub mod net;

/// The platform this machine registers with the hub as (`POST /v1/devices`).
#[cfg(target_os = "linux")]
pub const PLATFORM: &str = "linux";
#[cfg(windows)]
pub const PLATFORM: &str = "windows";

/// This host's command, named in next steps the person reads.
#[cfg(target_os = "linux")]
pub const COMMAND: &str = "cmux-rd linux-host";
#[cfg(windows)]
pub const COMMAND: &str = "cmux-rd windows-host";

/// Lowercase hex of `bytes`.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Bidi formatting characters: they reorder what a terminal shows (U+202E turns a name
/// around) though `char::is_control` does not count them.
pub(crate) fn is_bidi_control(c: char) -> bool {
    matches!(
        c,
        '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
    )
}

/// Text from the hub or a viewer, safe to print to a terminal or the journal: C0 and C1
/// controls, whole ANSI escape sequences (CSI, OSC and the like) and bidi controls removed.
pub(crate) fn printable(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                // CSI: parameters and intermediates, then one final character in @..~.
                Some('[') => {
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC, DCS, SOS, PM, APC: a string ended by BEL or ESC \.
                Some(']' | 'P' | 'X' | '^' | '_') => {
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                // A two-character escape (ESC c, ESC 7, ...).
                _ => {}
            },
            c if c.is_control() || is_bidi_control(c) => {}
            c => out.push(c),
        }
    }
    out
}
