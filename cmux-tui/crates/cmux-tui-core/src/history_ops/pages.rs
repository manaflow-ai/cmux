//! The page visit stores of the machine and the page part of every
//! `history.*` operation. [`run`] is pure over a [`VisitStores`] and a clock.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use cmux_history::{
    HistoryEntry, HistoryKind, HistoryQuery, HistoryRange, NewVisit, Removal, VisitStores,
};
use serde_json::{Map, Value, json};

use super::{DEFAULT_LIMIT, MAX_IDS, MAX_LIST, invalid, store_failed};
use crate::Mux;
use crate::resource::ResourceError;

/// Retention runs at most this often, lazily at an operation (no timer).
const PRUNE_EVERY_MS: i64 = 3_600_000;
/// `history.visit.summaries` answers at most this many URLs.
const MAX_SUMMARIES: u64 = 5000;
/// A long text field (URL) and a short one (title) as the catalog bounds them.
const MAX_URL_BYTES: usize = 8192;
const MAX_TITLE_BYTES: usize = 1024;
/// The file name of the app's own visit logs (`BrowserVisitLog`).
const LEGACY_LOG: &str = "History.sqlite";

pub(super) fn text<'a>(
    fields: &'a Map<String, Value>,
    name: &str,
) -> Result<Option<&'a str>, ResourceError> {
    match fields.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value)),
        Some(_) => Err(invalid(name, format!("{name} must be a non-empty string"))),
    }
}

fn required<'a>(
    fields: &'a Map<String, Value>,
    name: &str,
    max_bytes: usize,
) -> Result<&'a str, ResourceError> {
    text(fields, name)?
        .filter(|value| value.len() <= max_bytes)
        .ok_or_else(|| invalid(name, format!("{name} must be 1 to {max_bytes} bytes")))
}

pub(super) fn range(
    fields: &Map<String, Value>,
    required: bool,
) -> Result<HistoryRange, ResourceError> {
    match fields.get("range") {
        None if !required => Ok(HistoryRange::All),
        None => Err(invalid("range", "range is required: hour, today, week, month or all")),
        Some(value) => serde_json::from_value(value.clone())
            .map_err(|_| invalid("range", "range must be hour, today, week, month or all")),
    }
}

/// The query of a list request.
pub(super) fn query(fields: &Map<String, Value>) -> Result<HistoryQuery, ResourceError> {
    let limit = match fields.get("limit") {
        None => DEFAULT_LIMIT,
        Some(value) => value
            .as_u64()
            .filter(|limit| (1..=MAX_LIST as u64).contains(limit))
            .map(|limit| limit as usize)
            .ok_or_else(|| invalid("limit", format!("limit must be 1 to {MAX_LIST}")))?,
    };
    Ok(HistoryQuery {
        kinds: kinds(fields)?,
        // An empty search is no search (the catalog allows it).
        text: match fields.get("text") {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(text)) => text.clone(),
            Some(_) => return Err(invalid("text", "text must be a string")),
        },
        range: range(fields, false)?,
        limit: Some(limit),
    })
}

pub(super) fn kinds(fields: &Map<String, Value>) -> Result<Vec<HistoryKind>, ResourceError> {
    match fields.get("kinds") {
        None => Ok(Vec::new()),
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| {
            invalid("kinds", "kinds must list page, location, closed, command or agent")
        }),
    }
}

/// A `history:<32 hex>` restore id.
fn restore_id(fields: &Map<String, Value>) -> Result<&str, ResourceError> {
    let id = fields.get("restore_id").and_then(Value::as_str).unwrap_or("");
    let hex = id.strip_prefix("history:").unwrap_or("");
    if hex.len() != 32 || !hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(invalid("restore_id", "restore_id must be a history:<32 hex> restore id"));
    }
    Ok(id)
}

pub(super) fn removal(removal: &Removal) -> Value {
    json!({"removed": removal.removed, "restore_id": removal.restore_id})
}

/// The page entries of one profile: ids `page:<profile>:<number>`.
fn in_profile(id: &str, profile: &str) -> bool {
    id.strip_prefix("page:")
        .and_then(|rest| rest.strip_prefix(profile))
        .and_then(|rest| rest.strip_prefix(':'))
        .is_some_and(|number| !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()))
}

/// The catalog shape of an entry (`HistoryEntry`): the time is a decimal
/// string, as every v2 time.
pub(super) fn wire(entry: &HistoryEntry) -> Value {
    let mut value = serde_json::to_value(entry).unwrap_or(Value::Null);
    if let Some(object) = value.as_object_mut() {
        object.insert("at_ms".into(), Value::String(entry.at_ms.max(0).to_string()));
    }
    value
}

/// The page entries `query` reads, before the merge filters them: per
/// profile (or `profile` only), the newest `limit` visits at or after the
/// range's start whose folded text has every search token. The store
/// filters in SQL, so a search is never cut at a window of newest visits.
pub(super) fn entries(
    stores: &mut VisitStores,
    query: &HistoryQuery,
    profile: Option<&str>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<Vec<HistoryEntry>, cmux_history::HistoryError> {
    let pages = HistoryQuery {
        kinds: vec![HistoryKind::Page],
        limit: Some(query.limit.unwrap_or(DEFAULT_LIMIT)),
        ..query.clone()
    };
    let mut entries = stores.entries(&pages, now_ms, day_start_ms)?;
    if let Some(profile) = profile {
        entries.retain(|entry| in_profile(&entry.id, profile));
    }
    Ok(entries)
}

/// The host of `history.site.remove`, lowercased.
fn host(fields: &Map<String, Value>) -> Result<String, ResourceError> {
    Ok(text(fields, "host")?
        .filter(|host| {
            host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
                && !host.bytes().all(|b| b == b'.')
        })
        .ok_or_else(|| invalid("host", "host must be a host name such as example.com"))?
        .to_ascii_lowercase())
}

/// The ids of `history.entries.remove`: 1 to [`MAX_IDS`] strings.
pub(super) fn ids(fields: &Map<String, Value>) -> Result<Vec<&str>, ResourceError> {
    fields
        .get("ids")
        .and_then(Value::as_array)
        .filter(|ids| (1..=MAX_IDS).contains(&ids.len()))
        .and_then(|ids| ids.iter().map(Value::as_str).collect())
        .ok_or_else(|| invalid("ids", format!("ids must list 1 to {MAX_IDS} entry ids")))
}

/// The app's own visit log of one profile: an absolute path to an existing
/// file named `History.sqlite` (`BrowserVisitLog.fileURL`).
fn legacy_log(path: &str) -> Result<&std::path::Path, ResourceError> {
    let path = std::path::Path::new(path);
    if !path.is_absolute()
        || path.file_name().and_then(|name| name.to_str()) != Some(LEGACY_LOG)
        || !path.is_file()
    {
        return Err(invalid(
            "path",
            format!("path must be an existing absolute {LEGACY_LOG} file"),
        ));
    }
    Ok(path)
}

fn at_ms(fields: &Map<String, Value>) -> Result<i64, ResourceError> {
    fields
        .get("at_ms")
        .and_then(Value::as_str)
        .and_then(|text| text.parse::<i64>().ok())
        .filter(|at_ms| *at_ms >= 0)
        .ok_or_else(|| invalid("at_ms", "at_ms must be an unsigned decimal string"))
}

/// Answers the page part of one `history.*` operation on `stores` at
/// `now_ms` (`day_start_ms`: the local start of today, for range `today`).
/// `history.entries.list` here lists page visits only; the module merges
/// the other kinds (merged.rs).
pub(crate) fn run(
    stores: &mut VisitStores,
    operation: &str,
    fields: &Map<String, Value>,
    now_ms: i64,
    day_start_ms: i64,
) -> Result<Value, ResourceError> {
    let profile = text(fields, "profile")?;
    let failed = |error: cmux_history::HistoryError| store_failed(operation, error);
    match operation {
        "history.entries.list" => {
            let query = query(fields)?;
            if !query.wants(HistoryKind::Page) {
                return Ok(json!({"entries": []}));
            }
            let found = entries(stores, &query, profile, now_ms, day_start_ms).map_err(failed)?;
            let entries = cmux_history::apply(&query, &found, now_ms, day_start_ms, |_| false);
            Ok(json!({"entries": entries.iter().map(wire).collect::<Vec<_>>()}))
        }
        "history.entries.remove" => {
            stores.remove_ids(&ids(fields)?).map(|r| removal(&r)).map_err(failed)
        }
        "history.site.remove" => {
            stores.remove_host(&host(fields)?, profile).map(|r| removal(&r)).map_err(failed)
        }
        "history.clear" => {
            let since = range(fields, true)?.start(now_ms, day_start_ms);
            stores.clear(since, profile).map(|r| removal(&r)).map_err(failed)
        }
        "history.restore" => {
            let id = restore_id(fields)?;
            match stores.restore(id).map_err(failed)? {
                0 => Err(ResourceError::operation_failed(
                    operation,
                    format!("no history backup {id} (it was restored, purged or expired)"),
                    json!({}),
                )),
                restored => Ok(json!({"restored": restored})),
            }
        }
        "history.backups.purge" => {
            let id = restore_id(fields)?;
            let purged = stores.purge(id).map_err(failed)?;
            Ok(json!({"purged": purged}))
        }
        "history.visit.record" => {
            let profile = required(fields, "profile", 256)?;
            let visit = NewVisit {
                url: required(fields, "url", MAX_URL_BYTES)?.to_owned(),
                title: match text(fields, "title")? {
                    Some(title) if title.len() > MAX_TITLE_BYTES => {
                        return Err(invalid(
                            "title",
                            format!("title must be at most {MAX_TITLE_BYTES} bytes"),
                        ));
                    }
                    title => title.map(str::to_owned),
                },
                tab: text(fields, "tab")?.map(str::to_owned),
                at_ms: at_ms(fields)?,
            };
            let id = stores.record(profile, &visit).map_err(failed)?;
            Ok(json!({"id": id}))
        }
        "history.visit.title" => {
            let profile = required(fields, "profile", 256)?;
            let url = required(fields, "url", MAX_URL_BYTES)?;
            let title = required(fields, "title", MAX_TITLE_BYTES)?;
            let updated = stores.update_title(profile, url, title).map_err(failed)?;
            Ok(json!({"updated": updated}))
        }
        "history.visit.remove" => {
            let urls: Vec<&str> = fields
                .get("urls")
                .and_then(Value::as_array)
                .filter(|urls| (1..=MAX_IDS).contains(&urls.len()))
                .and_then(|urls| {
                    urls.iter()
                        .map(|url| {
                            url.as_str().filter(|url| (1..=MAX_URL_BYTES).contains(&url.len()))
                        })
                        .collect()
                })
                .ok_or_else(|| {
                    invalid(
                        "urls",
                        format!("urls must list 1 to {MAX_IDS} URLs of 1 to {MAX_URL_BYTES} bytes"),
                    )
                })?;
            stores.remove_urls(&urls, profile).map(|r| removal(&r)).map_err(failed)
        }
        "history.visit.import" => {
            let profile = required(fields, "profile", 256)?;
            let path = legacy_log(required(fields, "path", 4096)?)?;
            let imported = stores.import(profile, path).map_err(failed)?;
            Ok(json!({"imported": imported}))
        }
        "history.visit.summaries" => {
            let profile = required(fields, "profile", 256)?;
            let limit = match fields.get("limit") {
                None => MAX_SUMMARIES,
                Some(value) => {
                    value.as_u64().filter(|limit| (1..=MAX_SUMMARIES).contains(limit)).ok_or_else(
                        || invalid("limit", format!("limit must be 1 to {MAX_SUMMARIES}")),
                    )?
                }
            };
            let summaries = stores.summaries(profile, limit as usize).map_err(failed)?;
            Ok(Value::Array(
                summaries
                    .iter()
                    .map(|summary| {
                        json!({
                            "url": summary.url,
                            "title": summary.title,
                            "visit_count": u32::try_from(summary.visit_count).unwrap_or(u32::MAX),
                            "last_visit_ms": summary.last_visit_ms.max(0).to_string(),
                        })
                    })
                    .collect(),
            ))
        }
        other => Err(ResourceError::operation_failed(
            other,
            "the history module does not answer this operation",
            json!({}),
        )),
    }
}

/// The visit stores of one state directory and when they were last pruned.
pub(super) struct Shared {
    pub(super) stores: VisitStores,
    pruned_at_ms: i64,
}

/// The page history of the machine `mux` keeps state on: `<state>/history`
/// (0700) beside the session directories, so every session of the machine
/// shares one page history. A session without durable state has none
/// (`None`).
pub(super) fn shared(
    mux: &Mux,
    operation: &str,
) -> Result<Option<Arc<Mutex<Shared>>>, ResourceError> {
    static OPEN: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<Shared>>>>> = OnceLock::new();
    let Some(dir) = mux
        .session_state_directory()
        .and_then(|session| session.parent().map(|state| state.join("history")))
    else {
        return Ok(None);
    };
    let mut open = OPEN.get_or_init(Mutex::default).lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(shared) = open.get(&dir) {
        return Ok(Some(shared.clone()));
    }
    std::fs::create_dir_all(&dir)
        .and_then(|()| crate::platform::restrict_directory(&dir))
        .map_err(|e| store_failed(operation, format!("history directory: {e}")))?;
    let shared = Arc::new(Mutex::new(Shared {
        stores: VisitStores::new(dir.clone()),
        pruned_at_ms: i64::MIN,
    }));
    open.insert(dir, shared.clone());
    Ok(Some(shared))
}

/// Runs `body` on the machine's stores, after retention when it is due.
/// A session without durable state answers `operation.failed`.
pub(super) fn with_stores<T>(
    mux: &Mux,
    operation: &str,
    body: impl FnOnce(&mut VisitStores) -> Result<T, ResourceError>,
) -> Result<T, ResourceError> {
    let shared = shared(mux, operation)?.ok_or_else(|| {
        store_failed(operation, "this session keeps no durable state, so it has no page history")
    })?;
    let mut shared = shared.lock().unwrap_or_else(PoisonError::into_inner);
    let now = super::now_ms();
    if now.saturating_sub(shared.pruned_at_ms) >= PRUNE_EVERY_MS {
        // Retention (90 days, 100,000 visits) also ends old backups.
        shared.pruned_at_ms = now;
        let _ = shared.stores.prune(now);
    }
    body(&mut shared.stores)
}
