//! The browser automation's JSON ops (`browser_rules_automation_*`), served by [`crate::ops`].
//! Every op is pure; the app holds any state (a tab's [`LoadWaits`], its [`UrlWatch`]) and passes
//! it back in the next call.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_automation_load_state` | `{name}` | the [`LoadState`] name, or null |
//! | `browser_rules_automation_load_waits` | `{state, input}` ([`WaitInput`]) | `{state, resolved, ticket?, met?, pending?, ended?}` |
//! | `browser_rules_automation_blank_error_document` | `{committed, requested}` | a bool |
//! | `browser_rules_automation_url_change` | `{lastUrl, url, provisional, loading}` | `{lastUrl, sameDocument}` |
//! | `browser_rules_automation_cookie_in_scope` | `{domain, host}` | a bool |
//! | `browser_rules_automation_cookies_for_urls` | `{cookies, urls}` | the indexes of the cookies to answer |
//! | `browser_rules_automation_cookies_set` | `{cookies, now}` | `{cookies}` or `{error}` |
//! | `browser_rules_automation_cookies_clear_site` | `{url}` | `{host}` or `{error}` |
//! | `browser_rules_automation_cookies_clear_matches` | `{cookies, host, filter}` | the indexes of the cookies to delete |
//! | `browser_rules_automation_cookies_restore_plan` | `{cookies, existing, now}` | [`RestorePlan`] |
//! | `browser_rules_automation_same_site_label` | `{raw}` | the label |
//! | `browser_rules_automation_backups_full` | `{fileSizes, plainBytes, maxBackups?, maxBytes?}` | the refusal, or null |
//! | `browser_rules_automation_backup_file_hex` | `{restoreId}` | `{hex}` or `{error}` |
//! | `browser_rules_automation_backups_expired` | `{record, now}` or `{cookie, now}` | a bool, or null for a record with no cookie list |
//! | `browser_rules_automation_backup_summaries` | `{files}` ([`BackupFile`]) | the [`Summary`] list |

use crate::cookie_backups::{self, BackupFile, Summary};
use crate::cookies::{self, BackedUpCookie, ClearFilter, RestorePlan, StoredCookie};
use crate::load_waits::{self, LoadState, LoadWaits, NavigationEvent, Ticket};
use crate::ops::{OpError, encode, parse};
use crate::tab_watcher::UrlWatch;
use serde::Deserialize;
use serde_json::{Value, json};

/// One call into a tab's [`LoadWaits`].
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum WaitInput {
    /// [`LoadWaits::begin_navigation`]: replies `ticket`.
    Begin {
        #[serde(default, rename = "requestedUrl")]
        requested_url: Option<String>,
    },
    /// [`LoadWaits::navigation_event`].
    Navigation { event: NavigationEvent },
    /// [`LoadWaits::signal`].
    Signal { state: LoadState, document: String },
    /// [`LoadWaits::loading_ended`].
    LoadingEnded,
    /// [`LoadWaits::same_document`].
    SameDocument,
    /// [`LoadWaits::reach`]: replies `met`.
    Reach { id: u64, target: LoadState, ticket: Ticket },
    /// [`LoadWaits::expire`]: replies `pending`.
    Expire { id: u64 },
    /// [`LoadWaits::fail_all`]: replies `ended`.
    FailAll,
}

#[derive(Deserialize)]
struct WaitsRequest {
    #[serde(default)]
    state: LoadWaits,
    input: WaitInput,
}

#[derive(Deserialize)]
struct NameRequest {
    name: String,
}

#[derive(Deserialize)]
struct BlankRequest {
    #[serde(default)]
    committed: Option<String>,
    #[serde(default)]
    requested: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UrlChangeRequest {
    #[serde(default)]
    last_url: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    provisional: bool,
    #[serde(default)]
    loading: bool,
}

#[derive(Deserialize)]
struct ScopeRequest {
    domain: String,
    host: String,
}

#[derive(Deserialize)]
struct ForUrlsRequest {
    #[serde(default)]
    cookies: Vec<StoredCookie>,
    #[serde(default)]
    urls: Vec<String>,
}

#[derive(Deserialize)]
struct SetRequest {
    cookies: Vec<Value>,
    now: f64,
}

#[derive(Deserialize)]
struct ClearSiteRequest {
    #[serde(default)]
    url: Option<String>,
}

#[derive(Deserialize)]
struct ClearMatchesRequest {
    #[serde(default)]
    cookies: Vec<StoredCookie>,
    host: String,
    #[serde(default)]
    filter: ClearFilter,
}

#[derive(Deserialize)]
struct RestoreRequest {
    #[serde(default)]
    cookies: Vec<BackedUpCookie>,
    #[serde(default)]
    existing: Vec<StoredCookie>,
    now: f64,
}

#[derive(Deserialize)]
struct SameSiteRequest {
    raw: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FullRequest {
    #[serde(default)]
    file_sizes: Vec<u64>,
    plain_bytes: u64,
    #[serde(default)]
    max_backups: Option<usize>,
    #[serde(default)]
    max_bytes: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileHexRequest {
    restore_id: String,
}

#[derive(Deserialize)]
struct ExpiredRequest {
    #[serde(default)]
    record: Option<Value>,
    #[serde(default)]
    cookie: Option<Value>,
    now: f64,
}

#[derive(Deserialize)]
struct SummariesRequest {
    #[serde(default)]
    files: Vec<BackupFile>,
}

fn either<T: serde::Serialize>(result: Result<T, String>, key: &str) -> Value {
    match result {
        Ok(value) => json!({ key: encode(&value) }),
        Err(error) => json!({ "error": error }),
    }
}

fn load_waits(request: WaitsRequest) -> Value {
    let WaitsRequest { mut state, input } = request;
    let mut reply = json!({});
    let resolved = match input {
        WaitInput::Begin { requested_url } => {
            reply["ticket"] = encode(&state.begin_navigation(requested_url));
            Vec::new()
        }
        WaitInput::Navigation { event } => state.navigation_event(&event),
        WaitInput::Signal { state: next, document } => state.signal(next, &document),
        WaitInput::LoadingEnded => state.loading_ended(),
        WaitInput::SameDocument => state.same_document(),
        WaitInput::Reach { id, target, ticket } => {
            reply["met"] = json!(state.reach(id, target, &ticket));
            Vec::new()
        }
        WaitInput::Expire { id } => {
            reply["pending"] = json!(state.expire(id));
            Vec::new()
        }
        WaitInput::FailAll => {
            reply["ended"] = json!(state.fail_all());
            Vec::new()
        }
    };
    reply["resolved"] = encode(&resolved);
    reply["state"] = encode(&state);
    reply
}

/// Runs the automation op `op` on `request` (never null here).
pub(crate) fn call(op: &str, request: Value) -> Result<Value, OpError> {
    match op {
        "browser_rules_automation_load_state" => {
            let NameRequest { name } = parse(request)?;
            Ok(json!(LoadState::from_name(&name).map(LoadState::name)))
        }
        "browser_rules_automation_load_waits" => Ok(load_waits(parse(request)?)),
        "browser_rules_automation_blank_error_document" => {
            let BlankRequest { committed, requested } = parse(request)?;
            Ok(json!(load_waits::is_blank_error_document(
                committed.as_deref(),
                requested.as_deref()
            )))
        }
        "browser_rules_automation_url_change" => {
            let UrlChangeRequest { last_url, url, provisional, loading } = parse(request)?;
            let mut watch = UrlWatch { last_url };
            let same_document = watch.url_changed(url.as_deref(), provisional, loading);
            Ok(json!({ "lastUrl": watch.last_url, "sameDocument": same_document }))
        }
        "browser_rules_automation_cookie_in_scope" => {
            let ScopeRequest { domain, host } = parse(request)?;
            Ok(json!(cookies::in_scope(&domain, &host)))
        }
        "browser_rules_automation_cookies_for_urls" => {
            let ForUrlsRequest { cookies: stored, urls } = parse(request)?;
            Ok(json!(cookies::cookies_for_urls(&stored, &urls)))
        }
        "browser_rules_automation_cookies_set" => {
            let SetRequest { cookies: items, now } = parse(request)?;
            Ok(either(cookies::cookies_to_set(&items, now), "cookies"))
        }
        "browser_rules_automation_cookies_clear_site" => {
            let ClearSiteRequest { url } = parse(request)?;
            Ok(either(cookies::clear_site(url.as_deref()), "host"))
        }
        "browser_rules_automation_cookies_clear_matches" => {
            let ClearMatchesRequest { cookies: stored, host, filter } = parse(request)?;
            Ok(json!(cookies::clear_matches(&stored, &host, &filter)))
        }
        "browser_rules_automation_cookies_restore_plan" => {
            let RestoreRequest { cookies: backed_up, existing, now } = parse(request)?;
            let plan: RestorePlan = cookies::restore_plan(&backed_up, &existing, now);
            Ok(encode(&plan))
        }
        "browser_rules_automation_same_site_label" => {
            let SameSiteRequest { raw } = parse(request)?;
            Ok(json!(cookies::same_site_label(&raw)))
        }
        "browser_rules_automation_backups_full" => {
            let FullRequest { file_sizes, plain_bytes, max_backups, max_bytes } = parse(request)?;
            Ok(json!(cookie_backups::full(
                &file_sizes,
                plain_bytes,
                max_backups.unwrap_or(cookie_backups::DEFAULT_MAX_BACKUPS),
                max_bytes.unwrap_or(cookie_backups::DEFAULT_MAX_BYTES),
            )))
        }
        "browser_rules_automation_backup_file_hex" => {
            let FileHexRequest { restore_id } = parse(request)?;
            Ok(either(cookie_backups::file_hex(&restore_id), "hex"))
        }
        "browser_rules_automation_backups_expired" => match parse(request)? {
            ExpiredRequest { record: Some(record), now, .. } => {
                Ok(json!(cookie_backups::record_expired(&record, now)))
            }
            ExpiredRequest { cookie: Some(cookie), now, .. } => {
                Ok(json!(cookie_backups::expired(&cookie, now)))
            }
            _ => Err(OpError::Invalid("one of record or cookie".into())),
        },
        "browser_rules_automation_backup_summaries" => {
            let SummariesRequest { files } = parse(request)?;
            let list: Vec<Summary> = cookie_backups::summaries(&files);
            Ok(encode(&list))
        }
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}
