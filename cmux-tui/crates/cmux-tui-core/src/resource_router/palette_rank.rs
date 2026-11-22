//! `palette.rank` (read, `palette-rank-v1`, `palette-rank-v2`): ranks one palette request with
//! the shared ranker (`cmux-palette-ranker`), so a page ranks its rows the way
//! the app palette does without a ranker of its own.
//!
//! The params are a `RankRequest` that carries its own entries and history
//! (the JSON shape the ranker's C ABI takes); the result is `{sections}`,
//! exactly what `cmux_palette_ranker::rank_request` returns, and
//! `strictMatches`, the rows its strict pass matched. It is stateless:
//! nothing is installed or kept between calls.
//!
//! A catalog past one request's caps ranks in several requests: each with
//! `typoPass: false`, and all again with `typoPass: true` when their
//! `strictMatches` sum to fewer than the ranker's `TYPO_PASS_THRESHOLD`.
//! Their rows then merge by score and catalog order into the answer one
//! request over the whole catalog gives (paletteRank.ts `rankPalette`).
//!
//! The entry caps hold any title and name the app allows: a 200-character
//! title (`cmux_conversation::MAX_TITLE_CHARS`) with a channel's `#` is at
//! most 801 UTF-8 bytes (title cap 1024), and a conversation's 64
//! participants' 100-character names are at most 400 bytes each (keyword
//! caps 64 and 400).
//!
//! The catalog caps every list and string a page can send (entries, their
//! text, the query, pins and picks); the maps it cannot cap (the history's
//! entries and the aliases) are capped here, so one request costs a bounded
//! amount of work.

use std::sync::Arc;

use cmux_palette_ranker::{RankRequest, rank_request_answer};
use serde_json::{Map, Value, json};

use super::{ParsedResourceRequest, ensure_session_route};
use crate::Mux;
use crate::resource::ResourceError;

/// Advertised in identify: the daemon answers `palette.rank`.
pub(crate) const CAPABILITY: &str = "palette-rank-v1";
/// Advertised in identify: `palette.rank` takes `typoPass`, answers
/// `strictMatches`, and its entry caps are 1024-byte titles and 64 keywords of
/// 400 bytes (a v1 daemon refuses `typoPass` and has 512, 32 and 256).
pub(crate) const BATCH_CAPABILITY: &str = "palette-rank-v2";

/// Most usage-history entries (`frecency.entries`) one request may carry.
pub(crate) const MAX_HISTORY_ENTRIES: usize = 5_000;
/// Most aliased actions (`aliases`) one request may carry.
pub(crate) const MAX_ALIASED_ACTIONS: usize = 1_000;

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    rank(request.fields)
}

/// The answer to one catalog-validated request's fields.
pub(crate) fn rank(mut fields: Map<String, Value>) -> Result<Value, ResourceError> {
    // The catalog allows null for every optional field; null means absent (the ranker's
    // default), as `operation: null` must rank rather than fail.
    fields.retain(|_, value| !value.is_null());
    cap_map(&fields, "frecency", Some("entries"), MAX_HISTORY_ENTRIES)?;
    cap_map(&fields, "aliases", None, MAX_ALIASED_ACTIONS)?;
    let request: RankRequest = serde_json::from_value(Value::Object(fields))
        .map_err(|error| ResourceError::validation_invalid(None, error.to_string()))?;
    let answer = rank_request_answer(&request);
    Ok(json!({ "sections": answer.sections, "strictMatches": answer.strict_matches }))
}

/// Refuses a map field (`field`, or `field.inner`) with more than `maximum` keys.
fn cap_map(
    fields: &Map<String, Value>,
    field: &str,
    inner: Option<&str>,
    maximum: usize,
) -> Result<(), ResourceError> {
    let value = fields.get(field);
    let value = match inner {
        Some(inner) => value.and_then(|value| value.get(inner)),
        None => value,
    };
    let count = value.and_then(Value::as_object).map_or(0, Map::len);
    if count > maximum {
        let path = inner.map_or_else(|| field.to_owned(), |inner| format!("{field}.{inner}"));
        return Err(ResourceError::validation_invalid(
            Some(&path),
            format!("{path} has {count} keys; at most {maximum}"),
        ));
    }
    Ok(())
}
