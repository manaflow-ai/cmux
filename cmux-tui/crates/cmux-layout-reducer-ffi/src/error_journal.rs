//! `cmux-error-journal`'s rules over the JSON channel (ops `error_journal_*`): redaction,
//! templates, fingerprints, folding, what each segment write holds, queries, log, crash and
//! unified log parsing, and Copy Logs' text. The app opens one journal per directory, so one
//! [`ErrorJournals`] holds every open table by its id.
//!
//! Most of these ops change a journal (`record` folds, `flush` takes the dirty set), so running one
//! twice is not the same as running it once. A reply too big for the caller's buffer comes back as
//! `ERR_BUFFER` with its length, and the caller calls again with a bigger buffer: that retry, the
//! same op and request with room for the reply, gets the reply already made instead of a second run.
//! Any other call drops the kept reply.

use crate::ERR_INVALID;
use cmux_error_journal::ErrorJournals;
use std::sync::{Mutex, PoisonError};

static JOURNALS: Mutex<Option<ErrorJournals>> = Mutex::new(None);

/// The reply that did not fit, for the retry: (op, request, reply).
type Oversized = (Vec<u8>, Vec<u8>, Vec<u8>);

static OVERSIZED: Mutex<Option<Oversized>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(ErrorJournals::serves)
}

/// The reply for `operation` with `request`, for a caller with `capacity` bytes of room.
pub(crate) fn respond(operation: &[u8], request: &[u8], capacity: usize) -> Result<Vec<u8>, i32> {
    let mut oversized = OVERSIZED.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some((kept_operation, kept_request, reply)) = oversized.take()
        && kept_operation == operation
        && kept_request == request
    {
        if reply.len() > capacity {
            *oversized = Some((kept_operation, kept_request, reply.clone()));
        }
        return Ok(reply);
    }
    let reply = run(operation, request)?;
    if reply.len() > capacity {
        *oversized = Some((operation.to_vec(), request.to_vec(), reply.clone()));
    }
    Ok(reply)
}

fn run(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let mut journals = JOURNALS.lock().unwrap_or_else(PoisonError::into_inner);
    let reply = journals
        .get_or_insert_with(ErrorJournals::new)
        .call(operation, request)
        .map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(operation: &str, request: &str, capacity: usize) -> Vec<u8> {
        respond(operation.as_bytes(), request.as_bytes(), capacity).expect("reply")
    }

    #[test]
    fn a_retry_after_a_reply_too_big_gets_the_same_reply_without_a_second_run() {
        let journal = r#"{"journal":"/tmp/ffi-oversized-retry"}"#;
        call(
            "error_journal_open",
            r#"{"journal":"/tmp/ffi-oversized-retry","segments":[]}"#,
            1 << 20,
        );
        let events = r#"{"journal":"/tmp/ffi-oversized-retry","events":[{"source":"app","level":"error","message":"boom","context":{},"date":1.0}]}"#;
        call("error_journal_record", events, 1 << 20);
        let first = call("error_journal_flush", journal, 1);
        assert!(first.len() > 1);
        let retry = call("error_journal_flush", journal, first.len());
        assert_eq!(retry, first, "the retry is served the reply already made");
        let next = call("error_journal_flush", journal, 1 << 20);
        assert_ne!(next, first, "a fitting call is never served a kept reply");
        call("error_journal_close", journal, 1 << 20);
    }
}
