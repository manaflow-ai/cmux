//! `history list|search|remove|remove-site|clear-range|restore`: the session
//! host's history module (`history.*`, plans/cmux-next/react-pages.md 2.3),
//! so they work with the app quit. The other `history` words (`back`,
//! `show`, `clear`, `reopen`, ...) are app actions and route to the app
//! before this parser.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value};

use super::{
    CommandPlan, Flags, Selectors, UsageError, insert_bounded_u32, request, usage,
    validate_decimal, validate_one_of,
};

/// The `history` words the session host answers; every other word is an
/// app action.
pub(in crate::cli) const DAEMON_VERBS: &[&str] =
    &["list", "search", "remove", "remove-site", "clear-range", "restore"];

const KINDS: &[&str] = &["page", "location", "closed", "command", "agent"];
const RANGES: &[&str] = &["hour", "today", "week", "month", "all"];

pub(super) fn parse_history(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    let mut params = Map::new();
    let operation = match words {
        ["list"] => {
            query(flags, &mut params)?;
            Op::HistoryEntriesList
        }
        ["search", text @ ..] if !text.is_empty() => {
            params.insert("text".into(), Value::String(bounded("search text", &text.join(" "))?));
            query(flags, &mut params)?;
            Op::HistoryEntriesList
        }
        ["search"] => {
            let messages = &crate::localization::catalog().app_control;
            return Err(UsageError::new(messages.search_text_usage.replace("{scope}", "history")));
        }
        ["remove", ids @ ..] if !ids.is_empty() => {
            let ids = ids
                .iter()
                .map(|id| bounded("history entry id", id).map(Value::String))
                .collect::<Result<Vec<_>, _>>()?;
            params.insert("ids".into(), Value::Array(ids));
            Op::HistoryEntriesRemove
        }
        ["remove-site", host] => {
            params.insert("host".into(), Value::String(bounded("host", host)?));
            profile(flags, &mut params);
            Op::HistorySiteRemove
        }
        ["clear-range"] => {
            let range = flags.take("range").ok_or_else(|| {
                UsageError::new(
                    crate::localization::catalog().app_control.history_clear_range_usage,
                )
            })?;
            validate_one_of("--range", &range, RANGES)?;
            params.insert("range".into(), Value::String(range));
            kinds(flags, &mut params)?;
            profile(flags, &mut params);
            day_start(flags, &mut params)?;
            Op::HistoryClear
        }
        ["restore", restore_id] => {
            params.insert("restore_id".into(), Value::String(bounded("restore id", restore_id)?));
            Op::HistoryRestore
        }
        _ => return usage("history action"),
    };
    request(operation, &selectors, flags, params)
}

/// `--kind`, `--range`, `--profile`, `--limit` and `--local-day-start-ms`
/// of a list.
fn query(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<(), UsageError> {
    kinds(flags, params)?;
    if let Some(range) = flags.take("range") {
        validate_one_of("--range", &range, RANGES)?;
        params.insert("range".into(), Value::String(range));
    }
    profile(flags, params);
    if let Some(limit) = flags.take("limit") {
        insert_bounded_u32(params, "limit", "--limit", limit, 1, 5000)?;
    }
    day_start(flags, params)
}

/// `--kind page,agent`: a comma-separated list of entry kinds.
fn kinds(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<(), UsageError> {
    let Some(value) = flags.take("kind") else { return Ok(()) };
    let mut kinds = Vec::new();
    for kind in value.split(',').map(str::trim).filter(|kind| !kind.is_empty()) {
        validate_one_of("--kind", kind, KINDS)?;
        kinds.push(Value::String(kind.to_string()));
    }
    params.insert("kinds".into(), Value::Array(kinds));
    Ok(())
}

fn profile(flags: &mut Flags, params: &mut Map<String, Value>) {
    if let Some(profile) = flags.take("profile") {
        params.insert("profile".into(), Value::String(profile));
    }
}

fn day_start(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<(), UsageError> {
    if let Some(value) = flags.take("local-day-start-ms") {
        validate_decimal("--local-day-start-ms", &value)?;
        params.insert("local_day_start_ms".into(), Value::String(value));
    }
    Ok(())
}

fn bounded(what: &str, value: &str) -> Result<String, UsageError> {
    if value.is_empty() || value.len() > 1024 {
        let message = crate::localization::catalog().app_control.history_text_bytes;
        return Err(UsageError::new(message.replace("{what}", what)));
    }
    Ok(value.to_string())
}
