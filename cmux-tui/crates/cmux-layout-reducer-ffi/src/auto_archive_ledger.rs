//! Auto-archive ledger rules over the JSON channel: `auto_archive_ledger`.

use cmux_layout_reducer::auto_archive_ledger;

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"auto_archive_ledger"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request: auto_archive_ledger::Request =
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&auto_archive_ledger::respond(request)).map_err(|_| ERR_INVALID)
}
