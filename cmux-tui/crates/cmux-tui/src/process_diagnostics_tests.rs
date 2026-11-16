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
