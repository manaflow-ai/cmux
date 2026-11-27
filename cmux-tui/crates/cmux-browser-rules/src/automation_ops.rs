//! The `browser_rules_automation_*` ops: the browser automation's rules (load waits, cookie
//! backups, cookie matching, the tab watcher), served by [`crate::ops::call`]. Requests and
//! replies are camelCase JSON; every op is pure.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_automation_load_state` | `{name}` | `commit`, `domcontentloaded`, `load`, or null |
//! | `browser_rules_automation_load_waits` | `{waits?, do, ...}` | `{waits, resolved, ticket?, reach?, resolution?}` |
//! | `browser_rules_automation_blank_error_document` | `{committed, requested}` | a bool |
//! | `browser_rules_automation_backup_names` | `{bundleId}` | `{bundleName, keyService}` |
//! | `browser_rules_automation_backup_restore_id` | `{bytes}` (16) | the restore id |
//! | `browser_rules_automation_backup_file_name` | `{restoreId}` | `{fileName}` or `{error}` |
//! | `browser_rules_automation_backup_full` | `{sizes, plainBytes, maxBackups?, maxBytes?}` | the text, or null |
//! | `browser_rules_automation_backup_expired` | `{expires, now}` | a bool |
//! | `browser_rules_automation_backup_prune` | `{entries, now}` | the files to delete |
//! | `browser_rules_automation_backup_summaries` | `{entries}` | the list, newest first |
//! | `browser_rules_automation_backup_properties` | a backed-up cookie | the `HTTPCookie` properties |
//! | `browser_rules_automation_backup_restore_plan` | `{cookies, existing, now}` | an action per cookie |
//! | `browser_rules_automation_cookie_in_scope` | `{domain, host}` | a bool |
//! | `browser_rules_automation_cookie_listed` | `{cookie, urls}` | a bool |
//! | `browser_rules_automation_cookie_clear_matches` | `{cookies, host, filter}` | a bool per cookie |
//! | `browser_rules_automation_cookie_clear_site` | `{scheme, host}` | `{site}` or `{error}` |
//! | `browser_rules_automation_cookie_set_refusal` | `{expires, now}` | the text, or null |
//! | `browser_rules_automation_cookie_same_site` | `{policy}` | the label |
//! | `browser_rules_automation_cookie_playwright` | the fields | `{cookie}` or `{error}` |
//! | `browser_rules_automation_tab_url_changed` | `{lastUrl, url, loading, provisional}` | `{lastUrl, sameDocument}` |
//! | `browser_rules_automation_tab_fragment_only` | `{a, b}` | a bool |
//! | `browser_rules_automation_tab_process_exit_is_new` | `{exit, last}` | a bool |
//! | `browser_rules_automation_driver_params` | `{method, params, reads}` | `{values}` or `{error}` |
//! | `browser_rules_automation_call_deadline` | `{what, timeoutMs}` | `{milliseconds, message}` |
//! | `browser_rules_automation_tab_place` | a `tabs.open` call's params | `{workspace, terminal}` |
//! | `browser_rules_automation_frame_tree` | `{root}` | the frames, parents first |
//!
//! `browser_rules_automation_driver_params` reads each of `reads` (`{key, read, default?}`, `read`
//! one of `has`, `string`, `optionalString`, `number`, `optionalNumber`, `bool`, `strings`,
//! `array`, `timeout`) in order and answers the values, or the first read's error.
//!
//! `browser_rules_automation_load_waits` takes the machine's `waits` (absent: a new one), and
//! `do`: `snapshot`, `navigationEvent {event}`, `signal {state, document}`, `loadingEnded`,
//! `sameDocument`, `reach {target, ticket}`, `timedOut {wait, what, timeout}`, `failAll {error}`.
//! It answers the machine after the step and the `resolved` waits (each `{wait, error?}`).

use crate::load_waits::{
    self, LoadState, LoadWaits, NavigationEvent, Reach, Resolution, Ticket, WaitError,
};
use crate::ops::OpError;
use crate::{cookie_backups as backups, cookies, driver, frames, tab_watcher};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

fn result<T: serde::Serialize>(outcome: Result<T, String>, ok: &str) -> Value {
    match outcome {
        Ok(value) => json!({ ok: value }),
        Err(error) => json!({ "error": error }),
    }
}

#[derive(Deserialize)]
#[serde(tag = "do", rename_all = "camelCase")]
enum WaitsStep {
    Snapshot,
    NavigationEvent { event: NavigationEvent },
    Signal { state: LoadState, document: String },
    LoadingEnded,
    SameDocument,
    Reach { target: LoadState, ticket: Ticket },
    TimedOut { wait: u64, what: String, timeout: String },
    FailAll { error: WaitError },
}

#[derive(Deserialize)]
struct WaitsRequest {
    #[serde(default)]
    waits: LoadWaits,
    #[serde(flatten)]
    step: WaitsStep,
}

fn load_waits_op(request: Value) -> Result<Value, OpError> {
    let WaitsRequest { mut waits, step } = parse(request)?;
    let mut resolved: Vec<Resolution> = Vec::new();
    let mut extra = json!({});
    match step {
        WaitsStep::Snapshot => extra["ticket"] = encode(&waits.snapshot()),
        WaitsStep::NavigationEvent { event } => resolved = waits.navigation_event(&event),
        WaitsStep::Signal { state, document } => resolved = waits.signal(state, &document),
        WaitsStep::LoadingEnded => resolved = waits.loading_ended(),
        WaitsStep::SameDocument => resolved = waits.same_document(),
        WaitsStep::Reach { target, ticket } => {
            let reach: Reach = waits.reach(target, &ticket);
            extra["reach"] = encode(&reach);
        }
        WaitsStep::TimedOut { wait, what, timeout } => {
            extra["resolution"] = encode(&waits.timed_out(wait, &what, &timeout));
        }
        WaitsStep::FailAll { error } => resolved = waits.fail_all(&error),
    }
    extra["waits"] = encode(&waits);
    extra["resolved"] = encode(&resolved);
    Ok(extra)
}

#[derive(Deserialize)]
struct NameRequest {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BlankRequest {
    #[serde(default)]
    committed: Option<String>,
    #[serde(default)]
    requested: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BundleRequest {
    #[serde(default)]
    bundle_id: Option<String>,
}

#[derive(Deserialize)]
struct BytesRequest {
    bytes: [u8; 16],
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RestoreIdRequest {
    restore_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FullRequest {
    sizes: Vec<u64>,
    plain_bytes: u64,
    #[serde(default)]
    max_backups: Option<usize>,
    #[serde(default)]
    max_bytes: Option<u64>,
}

#[derive(Deserialize)]
struct ExpiresRequest {
    #[serde(default)]
    expires: Option<f64>,
    now: f64,
}

#[derive(Deserialize)]
struct PruneRequest {
    entries: Vec<backups::PruneEntry>,
    now: f64,
}

#[derive(Deserialize)]
struct SummariesRequest {
    entries: Vec<backups::SummaryEntry>,
}

#[derive(Deserialize)]
struct RestorePlanRequest {
    cookies: Vec<backups::BackedUpCookie>,
    #[serde(default)]
    existing: Vec<(String, String, String)>,
    now: f64,
}

#[derive(Deserialize)]
struct ScopeRequest {
    domain: String,
    host: String,
}

#[derive(Deserialize)]
struct ListedRequest {
    cookie: cookies::CookieFacts,
    #[serde(default)]
    urls: Vec<cookies::UrlParts>,
}

#[derive(Deserialize)]
struct ClearRequest {
    cookies: Vec<cookies::StoredCookie>,
    host: String,
    #[serde(default)]
    filter: cookies::ClearFilter,
}

#[derive(Deserialize)]
struct SiteRequest {
    #[serde(default)]
    scheme: Option<String>,
    #[serde(default)]
    host: Option<String>,
}

#[derive(Deserialize)]
struct PolicyRequest {
    policy: String,
}

#[derive(Deserialize)]
struct PairRequest {
    a: String,
    b: String,
}

#[derive(Deserialize)]
struct ExitRequest {
    #[serde(default)]
    exit: Option<Value>,
    #[serde(default)]
    last: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeadlineRequest {
    what: String,
    timeout_ms: f64,
}

#[derive(Deserialize)]
struct FrameTreeRequest {
    #[serde(default)]
    root: Option<frames::FrameNode>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum ReadKind {
    Has,
    String,
    OptionalString,
    Number,
    OptionalNumber,
    Bool,
    Strings,
    Array,
    Timeout,
}

#[derive(Deserialize)]
struct ParamRead {
    #[serde(default)]
    key: String,
    read: ReadKind,
    #[serde(default)]
    default: Option<Value>,
}

#[derive(Deserialize)]
struct DriverParamsRequest {
    method: String,
    #[serde(default)]
    params: Value,
    reads: Vec<ParamRead>,
}

fn read_param(params: &driver::DriverParams, read: &ParamRead) -> Result<Value, String> {
    let key = read.key.as_str();
    Ok(match read.read {
        ReadKind::Has => json!(params.has(key)),
        ReadKind::String => json!(params.string(key)?),
        ReadKind::OptionalString => json!(params.optional_string(key)?),
        ReadKind::Number => json!(params.number(key)?),
        ReadKind::OptionalNumber => json!(params.optional_number(key)?),
        ReadKind::Bool => {
            let fallback = read.default.as_ref().and_then(Value::as_bool).unwrap_or(false);
            json!(params.bool(key, fallback)?)
        }
        ReadKind::Strings => json!(params.strings(key)?),
        ReadKind::Array => Value::Array(params.array(key)?),
        ReadKind::Timeout => {
            let fallback =
                read.default.as_ref().and_then(Value::as_f64).unwrap_or(driver::DEFAULT_TIMEOUT_MS);
            json!(params.timeout_ms(fallback)?)
        }
    })
}

fn driver_params_op(request: Value) -> Result<Value, OpError> {
    let DriverParamsRequest { method, params, reads } = parse(request)?;
    let values = driver::DriverParams::new(&method, &params)
        .and_then(|params| reads.iter().map(|read| read_param(&params, read)).collect());
    Ok(result::<Vec<Value>>(values, "values"))
}

/// Runs the automation op `op`, or None when it is not one of them.
pub fn call(op: &str, request: Value) -> Option<Result<Value, OpError>> {
    let name = op.strip_prefix("browser_rules_automation_")?;
    Some(run(name, request))
}

fn run(name: &str, request: Value) -> Result<Value, OpError> {
    match name {
        "load_state" => {
            let NameRequest { name } = parse(request)?;
            Ok(json!(LoadState::from_name(&name).map(LoadState::name)))
        }
        "load_waits" => load_waits_op(request),
        "blank_error_document" => {
            let BlankRequest { committed, requested } = parse(request)?;
            Ok(json!(load_waits::is_blank_error_document(
                committed.as_deref(),
                requested.as_deref()
            )))
        }
        "backup_names" => {
            let BundleRequest { bundle_id } = parse(request)?;
            Ok(json!({
                "bundleName": backups::bundle_name(bundle_id.as_deref()),
                "keyService": backups::key_service(bundle_id.as_deref()),
            }))
        }
        "backup_restore_id" => {
            let BytesRequest { bytes } = parse(request)?;
            Ok(json!(backups::restore_id(&bytes)))
        }
        "backup_file_name" => {
            let RestoreIdRequest { restore_id } = parse(request)?;
            Ok(result(backups::backup_file_name(&restore_id), "fileName"))
        }
        "backup_full" => {
            let FullRequest { sizes, plain_bytes, max_backups, max_bytes } = parse(request)?;
            Ok(json!(backups::full(
                &sizes,
                plain_bytes,
                max_backups.unwrap_or(backups::DEFAULT_MAX_BACKUPS),
                max_bytes.unwrap_or(backups::DEFAULT_MAX_BYTES as u64),
            )))
        }
        "backup_expired" => {
            let ExpiresRequest { expires, now } = parse(request)?;
            Ok(json!(backups::expired(expires, now)))
        }
        "backup_prune" => {
            let PruneRequest { entries, now } = parse(request)?;
            Ok(json!(backups::prune_selection(&entries, now)))
        }
        "backup_summaries" => {
            let SummariesRequest { entries } = parse(request)?;
            Ok(encode(&backups::summaries(&entries)))
        }
        "backup_properties" => {
            let cookie: backups::BackedUpCookie = parse(request)?;
            Ok(encode(&cookie.properties()))
        }
        "backup_restore_plan" => {
            let RestorePlanRequest { cookies, existing, now } = parse(request)?;
            Ok(encode(&backups::restore_plan(&cookies, &existing, now)))
        }
        "cookie_in_scope" => {
            let ScopeRequest { domain, host } = parse(request)?;
            Ok(json!(cookies::in_scope(&domain, &host)))
        }
        "cookie_listed" => {
            let ListedRequest { cookie, urls } = parse(request)?;
            Ok(json!(cookies::cookie_listed(&cookie, &urls)))
        }
        "cookie_clear_matches" => {
            let ClearRequest { cookies: list, host, filter } = parse(request)?;
            let matched: Vec<bool> =
                list.iter().map(|cookie| cookies::clear_matches(cookie, &host, &filter)).collect();
            Ok(json!(matched))
        }
        "cookie_clear_site" => {
            let SiteRequest { scheme, host } = parse(request)?;
            Ok(result(cookies::clear_site(scheme.as_deref(), host.as_deref()), "site"))
        }
        "cookie_set_refusal" => {
            let ExpiresRequest { expires, now } = parse(request)?;
            Ok(json!(cookies::set_refusal(expires, now)))
        }
        "cookie_same_site" => {
            let PolicyRequest { policy } = parse(request)?;
            Ok(json!(cookies::same_site_label(&policy)))
        }
        "cookie_playwright" => {
            let fields: cookies::PlaywrightFields = parse(request)?;
            Ok(result(cookies::playwright_cookie(&fields), "cookie"))
        }
        "tab_url_changed" => {
            let change: tab_watcher::UrlChange = parse(request)?;
            Ok(encode(&tab_watcher::url_changed(&change)))
        }
        "tab_fragment_only" => {
            let PairRequest { a, b } = parse(request)?;
            Ok(json!(tab_watcher::differ_only_in_fragment(&a, &b)))
        }
        "tab_process_exit_is_new" => {
            let ExitRequest { exit, last } = parse(request)?;
            Ok(json!(tab_watcher::process_exit_is_new(exit.as_ref(), last.as_ref())))
        }
        "driver_params" => driver_params_op(request),
        "call_deadline" => {
            let DeadlineRequest { what, timeout_ms } = parse(request)?;
            let milliseconds = driver::deadline_ms(timeout_ms);
            Ok(json!({
                "milliseconds": milliseconds,
                "message": driver::timeout_message(&what, milliseconds),
            }))
        }
        "tab_place" => Ok(encode(&driver::TabPlace::from_params(&request))),
        "frame_tree" => {
            let FrameTreeRequest { root } = parse(request)?;
            Ok(encode(&root.map(|root| frames::flatten(&root)).unwrap_or_default()))
        }
        other => Err(OpError::UnknownOp(format!("browser_rules_automation_{other}"))),
    }
}
