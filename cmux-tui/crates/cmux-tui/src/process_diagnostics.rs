//! Bounded subprocess diagnostics that are safe to surface inside the TUI.

use std::io::Read;
use std::sync::Mutex;

pub(crate) struct BoundedDiagnosticBuffer {
    max_bytes: usize,
    state: Mutex<DiagnosticState>,
}

#[derive(Default)]
struct DiagnosticState {
    bytes: Vec<u8>,
    truncated: bool,
}

impl BoundedDiagnosticBuffer {
    pub(crate) fn new(max_bytes: usize) -> Self {
        Self { max_bytes, state: Mutex::new(DiagnosticState::default()) }
    }

    pub(crate) fn drain(&self, mut reader: impl Read) {
        let mut buffer = [0_u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => self.append(&buffer[..read]),
            }
        }
    }

    pub(crate) fn sanitized(&self, redactions: &[String]) -> Option<String> {
        let state = self.state.lock().ok()?;
        if state.bytes.is_empty() && !state.truncated {
            return None;
        }
        let mut text = String::from_utf8_lossy(&state.bytes).into_owned();
        for secret in redactions {
            if !secret.is_empty() {
                text = text.replace(secret, "[redacted]");
            }
        }
        let mut sanitized = String::with_capacity(text.len().min(self.max_bytes));
        let mut pending_space = false;
        for character in text.chars() {
            if character.is_whitespace() || character.is_control() {
                pending_space = !sanitized.is_empty();
            } else {
                if pending_space {
                    sanitized.push(' ');
                    pending_space = false;
                }
                sanitized.push(character);
            }
        }
        if state.truncated {
            if !sanitized.is_empty() {
                sanitized.push(' ');
            }
            sanitized.push_str("[truncated]");
        }
        (!sanitized.is_empty()).then_some(sanitized)
    }

    fn append(&self, bytes: &[u8]) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let remaining = self.max_bytes.saturating_sub(state.bytes.len());
        state.bytes.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
        state.truncated |= bytes.len() > remaining;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_sanitizes_and_optionally_redacts_diagnostics() {
        let diagnostics = BoundedDiagnosticBuffer::new(13);
        diagnostics.append(b"secret\nunsafe\x1b[31m text that is too long");

        let sanitized = diagnostics.sanitized(&["secret".into()]).unwrap();
        assert_eq!(sanitized, "[redacted] unsafe [truncated]");
        assert!(!sanitized.contains('\u{1b}'));
    }
}
