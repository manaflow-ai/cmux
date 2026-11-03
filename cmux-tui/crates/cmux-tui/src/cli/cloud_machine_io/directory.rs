//! Bounded guest pages, spooled as one legacy JSON body without an aggregate limit.
use std::io::Write as _;

use serde_json::Value;

use super::direct::{Direct, Grant, fs};
use super::{Answer, Spool, private_spool, storage_error};

pub(super) const PROGRAM: &str = include_str!("directory_page.py");
pub(super) const PAGE_ENTRIES: u32 = 10_000;
pub(super) const PAGE_BYTES: u32 = 2 * 1024 * 1024;
pub(super) const CHANGED: i32 = 51;
pub(super) const INVALID_CURSOR: i32 = 52;

pub(super) async fn read(
    client: &reqwest::Client,
    grant: &Grant,
    path: &str,
) -> Result<Answer, Direct> {
    let mut file =
        std::io::BufWriter::with_capacity(64 * 1024, private_spool().map_err(storage_error)?);
    file.write_all(b"{\"entries\":[").map_err(storage_error)?;
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
            if has_entries {
                file.write_all(b",").map_err(storage_error)?;
            }
            serde_json::to_writer(&mut file, entry)
                .map_err(|error| storage_error(std::io::Error::other(error)))?;
            has_entries = true;
        }
        match next {
            Some(next) => cursor.clone_from(next),
            None => break,
        }
    }
    file.write_all(b"]}").map_err(storage_error)?;
    let file = file.into_inner().map_err(|error| storage_error(error.into_error()))?;
    Ok(Answer { status: 200, body: Value::Null, code: None, file: Some(Spool::Json(file)) })
}
