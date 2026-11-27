//! Bounded guest pages, spooled as one legacy JSON body, up to the request's `max_bytes`.
use std::io::Write as _;

use serde_json::Value;

use super::direct::{Direct, Grant, fs};
use super::{Answer, Spool, private_spool, storage_error};

pub(super) const PROGRAM: &str = include_str!("directory_page.py");
pub(super) const PAGE_ENTRIES: u32 = 10_000;
pub(super) const PAGE_BYTES: u32 = 2 * 1024 * 1024;
pub(super) const CHANGED: i32 = 51;
pub(super) const INVALID_CURSOR: i32 = 52;

const OPEN: &[u8] = b"{\"entries\":[";
const CLOSE: &[u8] = b"]}";

pub(super) async fn read(
    client: &reqwest::Client,
    grant: &Grant,
    path: &str,
    max_bytes: Option<u64>,
) -> Result<Answer, Direct> {
    let limit = max_bytes.unwrap_or(u64::MAX);
    // Every byte the listing writes, its closing `]}` reserved up front.
    let mut written = (OPEN.len() as u64).saturating_add(CLOSE.len() as u64);
    if written > limit {
        return Err(Direct::Done(Answer::too_large(limit)));
    }
    let mut file =
        std::io::BufWriter::with_capacity(64 * 1024, private_spool().map_err(storage_error)?);
    file.write_all(OPEN).map_err(storage_error)?;
    let mut cursor = String::new();
    let mut has_entries = false;
    loop {
        let page = fs(client, grant, "dir", path, &[cursor.clone()], None).await?;
        let entries = page.get("entries").and_then(Value::as_array).ok_or(Direct::Fallback)?;
        let next = match page.get("nextCursor") {
            Some(Value::Null) => None,
            Some(Value::String(next))
                if !next.is_empty() && next.len() <= 512 && *next != cursor =>
            {
                Some(next)
            }
            _ => return Err(Direct::Fallback),
        };
        // Refuse malformed provider pages before allocating or emitting a whole directory.
        if entries.len() > PAGE_ENTRIES as usize || (next.is_some() && entries.is_empty()) {
            return Err(Direct::Fallback);
        }
        for entry in entries {
            let bytes = serde_json::to_vec(entry)
                .map_err(|error| storage_error(std::io::Error::other(error)))?;
            let comma = u64::from(has_entries);
            written = written.saturating_add(comma).saturating_add(bytes.len() as u64);
            if written > limit {
                // Refused while listing: no later page is fetched or spooled.
                return Err(Direct::Done(Answer::too_large(limit)));
            }
            if has_entries {
                file.write_all(b",").map_err(storage_error)?;
            }
            file.write_all(&bytes).map_err(storage_error)?;
            has_entries = true;
        }
        match next {
            Some(next) => cursor.clone_from(next),
            None => break,
        }
    }
    file.write_all(CLOSE).map_err(storage_error)?;
    let file = file.into_inner().map_err(|error| storage_error(error.into_error()))?;
    Ok(Answer { status: 200, body: Value::Null, code: None, file: Some(Spool::Json(file)) })
}
