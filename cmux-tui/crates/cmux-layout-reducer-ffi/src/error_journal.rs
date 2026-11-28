//! `cmux-error-journal`'s rules over the JSON channel (ops `error_journal_*`): redaction,
//! templates, fingerprints, folding, what each segment write holds, queries, log, crash and
//! unified log parsing, and Copy Logs' text. The app opens one journal per directory, so one
//! [`ErrorJournals`] holds every open table by its id.

use crate::ERR_INVALID;
use cmux_error_journal::ErrorJournals;
use std::sync::{Mutex, PoisonError};

static JOURNALS: Mutex<Option<ErrorJournals>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(ErrorJournals::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
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
