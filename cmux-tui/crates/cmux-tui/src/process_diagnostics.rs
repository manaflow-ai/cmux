//! Bounded subprocess diagnostics that are safe to surface inside the TUI.

use std::io::{self, Read};
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::sync::Mutex;

use zeroize::Zeroize;

pub(crate) struct BoundedDiagnosticBuffer {
    max_bytes: usize,
    state: Mutex<DiagnosticState>,
}

#[derive(Default)]
struct DiagnosticState {
    redactions: Vec<Vec<u8>>,
    bytes: Vec<u8>,
    pending: Vec<u8>,
    truncated: bool,
}

impl BoundedDiagnosticBuffer {
    pub(crate) fn new(max_bytes: usize) -> Self {
        Self::with_redactions(max_bytes, &[])
    }

    pub(crate) fn with_redactions(max_bytes: usize, redactions: &[String]) -> Self {
        let mut redactions = redactions
            .iter()
            .filter(|secret| !secret.is_empty())
            .map(|secret| secret.as_bytes().to_vec())
            .collect::<Vec<_>>();
        redactions.sort();
        redactions.dedup();
        redactions.sort_by_key(|secret| std::cmp::Reverse(secret.len()));
        Self {
            max_bytes,
            state: Mutex::new(DiagnosticState { redactions, ..DiagnosticState::default() }),
        }
    }

    /// Adds a secret before it can cross into the observed process. Existing
    /// diagnostics are intentionally left untouched, so callers must register
    /// every per-request secret before writing it to the child.
    pub(crate) fn add_redaction(&self, secret: &str) {
        if secret.is_empty() {
            return;
        }
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let secret = secret.as_bytes();
        if state.redactions.iter().any(|redaction| redaction == secret) {
            return;
        }
        state.redactions.push(secret.to_vec());
        state.redactions.sort_by_key(|secret| std::cmp::Reverse(secret.len()));
    }

    #[cfg(any(not(unix), test))]
    pub(crate) fn drain(&self, mut reader: impl Read) {
        let mut buffer = [0_u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    self.finish();
                    return;
                }
                Ok(read) => self.append(&buffer[..read]),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    self.finish();
                    return;
                }
            }
        }
    }

    #[cfg(unix)]
    pub(crate) fn drain_cancellable(&self, mut reader: impl Read + AsRawFd, cancel: UnixStream) {
        let mut poll_fds = [
            libc::pollfd { fd: cancel.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: reader.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        let terminal_events = libc::POLLIN | libc::POLLHUP | libc::POLLERR | libc::POLLNVAL;
        let mut buffer = [0_u8; 4096];
        loop {
            let ready = unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, -1) };
            if ready < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                self.finish();
                return;
            }
            if poll_fds[0].revents & terminal_events != 0 {
                self.cancel();
                return;
            }
            if poll_fds[1].revents & terminal_events == 0 {
                continue;
            }
            match reader.read(&mut buffer) {
                Ok(0) => {
                    self.finish();
                    return;
                }
                Ok(read) => self.append(&buffer[..read]),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    self.finish();
                    return;
                }
            }
        }
    }

    pub(crate) fn sanitized(&self) -> Option<String> {
        let state = self.state.lock().ok()?;
        if state.bytes.is_empty() && state.pending.is_empty() && !state.truncated {
            return None;
        }
        // A pending suffix may be the beginning of a redaction split across
        // reads. Do not surface it until EOF or another read proves it safe.
        let text = String::from_utf8_lossy(&state.bytes);
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
        if state.truncated {
            return;
        }
        let mut combined = std::mem::take(&mut state.pending);
        combined.extend_from_slice(bytes);
        let (redacted, pending) = redact_committed(&combined, &state.redactions);
        append_bounded(&mut state, &redacted, self.max_bytes);
        if !state.truncated {
            state.pending = pending;
        }
    }

    fn finish(&self) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let pending = std::mem::take(&mut state.pending);
        let pending = redact(&pending, &state.redactions);
        append_bounded(&mut state, &pending, self.max_bytes);
    }

    fn cancel(&self) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        state.pending.zeroize();
        state.pending.clear();
    }
}

fn append_bounded(state: &mut DiagnosticState, bytes: &[u8], max_bytes: usize) {
    let remaining = max_bytes.saturating_sub(state.bytes.len());
    state.bytes.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
    state.truncated |= bytes.len() > remaining;
}

fn redact_committed(bytes: &[u8], redactions: &[Vec<u8>]) -> (Vec<u8>, Vec<u8>) {
    const REPLACEMENT: &[u8] = b"[redacted]";
    let mut redacted = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if let Some(secret) = redactions.iter().find(|secret| bytes[index..].starts_with(secret)) {
            redacted.extend_from_slice(REPLACEMENT);
            index += secret.len();
        } else if redactions
            .iter()
            .any(|secret| bytes.len() - index < secret.len() && secret.starts_with(&bytes[index..]))
        {
            return (redacted, bytes[index..].to_vec());
        } else {
            redacted.push(bytes[index]);
            index += 1;
        }
    }
    (redacted, Vec::new())
}

fn redact(bytes: &[u8], redactions: &[Vec<u8>]) -> Vec<u8> {
    const REPLACEMENT: &[u8] = b"[redacted]";
    let mut redacted = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if let Some(secret) = redactions.iter().find(|secret| bytes[index..].starts_with(secret)) {
            redacted.extend_from_slice(REPLACEMENT);
            index += secret.len();
        } else {
            redacted.push(bytes[index]);
            index += 1;
        }
    }
    redacted
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[test]
    fn bounds_sanitizes_and_optionally_redacts_diagnostics() {
        let diagnostics = BoundedDiagnosticBuffer::with_redactions(17, &["secret".into()]);
        diagnostics.append(b"secret\nunsafe\x1b[31m text that is too long");

        let sanitized = diagnostics.sanitized().unwrap();
        assert_eq!(sanitized, "[redacted] unsafe [truncated]");
        assert!(!sanitized.contains('\u{1b}'));
    }

    #[test]
    fn redacts_a_secret_split_between_capture_chunks_before_storage() {
        let diagnostics = BoundedDiagnosticBuffer::with_redactions(64, &["split-secret".into()]);
        diagnostics.append(b"failure: split-");
        assert_eq!(diagnostics.sanitized().as_deref(), Some("failure:"));
        diagnostics.append(b"secret was rejected");

        let state = diagnostics.state.lock().unwrap();
        assert!(!state.bytes.windows(b"split-secret".len()).any(|part| part == b"split-secret"));
        drop(state);
        let sanitized = diagnostics.sanitized().unwrap();
        assert_eq!(sanitized, "failure: [redacted] was rejected");
        assert!(!sanitized.contains("split-secret"));
    }

    #[test]
    fn applies_the_cap_after_redaction_and_handles_self_overlapping_secrets() {
        let diagnostics = BoundedDiagnosticBuffer::with_redactions(10, &["aaaa".into()]);
        diagnostics.append(b"aaaa");

        let state = diagnostics.state.lock().unwrap();
        assert_eq!(state.bytes, b"[redacted]");
        assert!(state.pending.is_empty());
        assert!(!state.truncated);
        drop(state);
        assert_eq!(diagnostics.sanitized().as_deref(), Some("[redacted]"));
    }

    #[test]
    fn drain_retries_interrupted_reads() {
        let diagnostics = BoundedDiagnosticBuffer::new(64);
        diagnostics.drain(InterruptedOnce {
            reads: VecDeque::from([Err(io::ErrorKind::Interrupted), Ok(b"diagnostic".to_vec())]),
        });
        assert_eq!(diagnostics.sanitized().as_deref(), Some("diagnostic"));
    }

    struct InterruptedOnce {
        reads: VecDeque<Result<Vec<u8>, io::ErrorKind>>,
    }

    impl Read for InterruptedOnce {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            match self.reads.pop_front() {
                Some(Ok(bytes)) => {
                    buffer[..bytes.len()].copy_from_slice(&bytes);
                    Ok(bytes.len())
                }
                Some(Err(kind)) => Err(io::Error::from(kind)),
                None => Ok(0),
            }
        }
    }
}
