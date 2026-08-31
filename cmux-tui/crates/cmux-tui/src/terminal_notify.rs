//! Desktop notifications through the client's host terminal.
//!
//! Ported from herdrdev/herdr `src/terminal_notify.rs` at commit
//! 7b675f42af35 (Apache-2.0, see `cmux-tui/ATTRIBUTIONS.md`), modified by
//! manaflow: the emitter returns the encoded sequence so the caller (the
//! attached TUI client) writes it through its own stdout alongside the
//! renderer, a BEL rides along for an audible cue, and backend detection
//! reads the environment once instead of per call.
//!
//! Alerts are presentation: the daemon never emits these. Each attached
//! client decides from its own config and focus which transitions it
//! surfaces, exactly like the seen bit.

use std::io::{self, Write as _};
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalNotificationBackend {
    Ghostty,
    Iterm2,
    Kitty,
    WezTerm,
}

/// The host terminal this client is attached to, detected once. `None`
/// means no known notification backend; alerts are dropped silently.
pub(crate) fn backend() -> Option<TerminalNotificationBackend> {
    static BACKEND: OnceLock<Option<TerminalNotificationBackend>> = OnceLock::new();
    *BACKEND.get_or_init(detect_backend)
}

fn detect_backend() -> Option<TerminalNotificationBackend> {
    let term_program = std::env::var("TERM_PROGRAM").ok();
    let term = std::env::var("TERM").ok();
    match term_program.as_deref() {
        Some("ghostty") => return Some(TerminalNotificationBackend::Ghostty),
        Some("iTerm.app") => return Some(TerminalNotificationBackend::Iterm2),
        Some("WezTerm") => return Some(TerminalNotificationBackend::WezTerm),
        _ => {}
    }
    if std::env::var_os("KITTY_WINDOW_ID").is_some() {
        return Some(TerminalNotificationBackend::Kitty);
    }
    match term.as_deref() {
        Some("xterm-ghostty") => Some(TerminalNotificationBackend::Ghostty),
        Some("xterm-kitty") => Some(TerminalNotificationBackend::Kitty),
        Some(term) if term.contains("wezterm") => Some(TerminalNotificationBackend::WezTerm),
        _ => None,
    }
}

/// Encode a notification for `backend`, tmux-wrapped when this client runs
/// inside tmux. Pure so tests pin the exact bytes.
pub(crate) fn encode_notification(
    backend: TerminalNotificationBackend,
    inside_tmux: bool,
    title: &str,
    body: Option<&str>,
) -> Vec<u8> {
    let mut sequence = match backend {
        TerminalNotificationBackend::Ghostty
        | TerminalNotificationBackend::Iterm2
        | TerminalNotificationBackend::WezTerm => build_osc9_notification(title, body),
        TerminalNotificationBackend::Kitty => build_osc99_notification(title, body),
    };
    if inside_tmux {
        sequence = wrap_tmux_passthrough(&sequence);
    }
    // BEL after the (possibly wrapped) notification: an audible cue via the
    // host terminal's bell handling, never wrapped so tmux still sees it.
    sequence.push(0x07);
    sequence
}

/// Emit a notification through this process's stdout. Returns `Ok(false)`
/// when no known backend is attached.
pub(crate) fn show_notification(title: &str, body: Option<&str>) -> io::Result<bool> {
    let Some(backend) = backend() else {
        return Ok(false);
    };
    let sequence = encode_notification(backend, std::env::var_os("TMUX").is_some(), title, body);
    let mut stdout = io::stdout();
    stdout.write_all(&sequence)?;
    stdout.flush()?;
    Ok(true)
}

fn build_osc9_notification(title: &str, body: Option<&str>) -> Vec<u8> {
    let message = sanitize_text(match body {
        Some(body) if !body.is_empty() => format!("{title}: {body}"),
        _ => title.to_string(),
    });
    format!("\x1b]9;{message}\x1b\\").into_bytes()
}

fn build_osc99_notification(title: &str, body: Option<&str>) -> Vec<u8> {
    let title = sanitize_text(title);
    match body {
        Some(body) if !body.is_empty() => {
            let body = sanitize_text(body);
            format!("\x1b]99;i=1:d=0;{title}\x1b\\\x1b]99;i=1:p=body;{body}\x1b\\").into_bytes()
        }
        _ => format!("\x1b]99;;{title}\x1b\\").into_bytes(),
    }
}

fn sanitize_text(text: impl AsRef<str>) -> String {
    text.as_ref()
        .chars()
        .filter(|ch| *ch != '\u{1b}' && *ch != '\u{7}' && *ch != '\u{9c}')
        .map(|ch| match ch {
            '\n' | '\r' | '\t' => ' ',
            _ => ch,
        })
        .collect()
}

fn wrap_tmux_passthrough(sequence: &[u8]) -> Vec<u8> {
    let mut wrapped = Vec::with_capacity(sequence.len() + 16);
    wrapped.extend_from_slice(b"\x1bPtmux;");
    for &byte in sequence {
        if byte == 0x1b {
            wrapped.push(0x1b);
        }
        wrapped.push(byte);
    }
    wrapped.extend_from_slice(b"\x1b\\");
    wrapped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_alert_osc9_carries_title_body_and_bel() {
        let sequence = encode_notification(
            TerminalNotificationBackend::Ghostty,
            false,
            "claude blocked",
            Some("ws · needs input"),
        );
        assert_eq!(sequence, "\x1b]9;claude blocked: ws \u{b7} needs input\x1b\\\x07".as_bytes());
    }

    #[test]
    fn agent_alert_kitty_uses_structured_title_and_body() {
        let sequence = String::from_utf8(encode_notification(
            TerminalNotificationBackend::Kitty,
            false,
            "pi finished",
            Some("ws · 1"),
        ))
        .expect("utf8");
        assert!(sequence.contains("]99;i=1:d=0;pi finished"));
        assert!(sequence.contains("]99;i=1:p=body;ws · 1"));
        assert!(sequence.ends_with('\u{7}'));
    }

    #[test]
    fn agent_alert_sanitizes_control_bytes_from_untrusted_titles() {
        let sequence = encode_notification(
            TerminalNotificationBackend::Ghostty,
            false,
            "a\n\tb\u{1b}c\u{7}",
            None,
        );
        assert_eq!(sequence, b"\x1b]9;a  bc\x1b\\\x07");
    }

    #[test]
    fn agent_alert_tmux_passthrough_wraps_and_escapes_but_not_the_bel() {
        let sequence = encode_notification(TerminalNotificationBackend::Ghostty, true, "hi", None);
        assert_eq!(sequence, b"\x1bPtmux;\x1b\x1b]9;hi\x1b\x1b\\\x1b\\\x07");
    }
}
