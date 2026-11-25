//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `browser_rules_*`). Every op is pure. Requests and replies are
//! in the shape Swift's synthesized `Codable` gives the app's types ([`crate::links`]).
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_is_top_level_domain` | `{label}` or `{labels}` | a bool, or one per label |
//! | `browser_rules_host_typo_fix` | `{text}` | [`TypoFix`](crate::address::TypoFix) `{text, typedHost}`, or null |
//! | `browser_rules_https_upgrade_falls_back` | `{domain, code}` | a bool |
//! | `browser_rules_calculator_answer` | `{text}` | the answer text, or null when `text` is not arithmetic |
//! | `browser_rules_link_gesture` | `{command, shift, option, button}` | the [`Gesture`] |
//! | `browser_rules_link_action` | `{mapping, gesture}` | the [`LinkAction`](crate::links::LinkAction) |
//! | `browser_rules_webkit_link_click` | `{command, shift, option, button, mapping}` | [`WebKitLinkClick`] |
//! | `browser_rules_cef_link_placement` | `{disposition, userGesture, click, now, mapping}` | [`LinkPlacement`] |
//! | `browser_rules_window_placement` | `{request, links}` | [`LinkPlacement`] |
//! | `browser_rules_window_decide` | `{request, candidates, links}` | [`WindowDecision`] |
//! | `browser_rules_profile_resolve` | `{explicit, workspace, room, known}` | the profile id a new tab gets |
//! | `browser_rules_profile_source` | `{tabProfile, workspace, room, known}` | [`CascadeSource`](crate::profiles::CascadeSource) |
//! | `browser_rules_profile_shows_tab_badge` | `{tabProfile, workspaceEffective}` | a bool |
//! | `browser_rules_profile_is_valid_id` | `{id}` | a bool |
//! | `browser_rules_profile_engine_profile` | `{id}` | the engine profile UUID, or null |
//! | `browser_rules_profile_wire_id` | `{profile}` | the wire id |
//! | `browser_rules_profile_monogram` | `{record}` | what the badge shows |
//! | `browser_rules_profile_proxy` | `{proxy}` | `{chromiumServer, chromiumBypassList, webKitPort, webKitExcludedDomains}` |
//! | `browser_rules_profile_valid_name` | `{name}` | `{ok}` or `{error}` ([`ProfileBookError`]) |
//! | `browser_rules_profile_valid_color` | `{color}` | `{ok}` or `{error}` |
//! | `browser_rules_profile_valid_icon` | `{icon}` | `{ok}` or `{error}` |
//! | `browser_rules_profile_book_read` | `{book, defaultName}` | the [`ProfileBook`] |
//! | `browser_rules_profile_book_ordered` | `{book}` | the records in display order |
//! | `browser_rules_profile_book_engine_profile` | `{book, id}` | the engine profile UUID |
//! | `browser_rules_profile_book_edit` | `{book, defaultName, edit}` | `{book, record}` or `{error}` |
//! | `browser_rules_profile_chromium_directories` | `{id, names}` | the directory names |
//! | `browser_rules_profile_cleanup_claim` | `{claims, pending, open}` | `{claims, ready}` |
//! | `browser_rules_profile_cleanup_release` | `{claims, ids}` | the claims |
//! | `browser_rules_profile_off_the_record_begin` | `{state, profile}` | the state |
//! | `browser_rules_profile_off_the_record_end` | `{state, profile}` | `{state, ended}` |
//! | `browser_rules_profile_off_the_record_is` | `{state, profile}` | `{active, offTheRecord}` |
//!
//! A book in a request is the stored book file's JSON, read as the app reads it
//! ([`ProfileBook::from_json`]; `defaultName` names a default profile it lacks, else `Default`).

use crate::links::{
    self, CefDisposition, ClickMapping, ClickRecord, Gesture, LinkContext, LinkPlacement,
    Modifiers, WebKitLinkClick, WindowCandidate, WindowDecision, WindowRequest,
};
use crate::profiles::{
    self, BrowserProfileId, CleanupClaims, OffTheRecordProfiles, ProfileBook, ProfileBookError,
    ProfileProxy, ProfileRecord,
};
use crate::{address, calculator};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes.
    Invalid(String),
}

#[derive(Deserialize)]
struct TldRequest {
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    labels: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
struct LoadErrorRequest {
    domain: String,
    code: i64,
}

#[derive(Deserialize)]
struct GestureRequest {
    #[serde(flatten)]
    modifiers: Modifiers,
    #[serde(default)]
    button: i64,
}

#[derive(Deserialize)]
struct WebKitClickRequest {
    #[serde(flatten)]
    modifiers: Modifiers,
    #[serde(default)]
    button: i64,
    #[serde(default)]
    mapping: ClickMapping,
}

#[derive(Deserialize)]
struct ActionRequest {
    #[serde(default)]
    mapping: ClickMapping,
    gesture: Gesture,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CefPlacementRequest {
    disposition: CefDisposition,
    #[serde(default)]
    user_gesture: bool,
    #[serde(default)]
    click: Option<ClickRecord>,
    #[serde(default)]
    now: f64,
    #[serde(default)]
    mapping: ClickMapping,
}

#[derive(Deserialize)]
struct WindowOpRequest {
    request: WindowRequest,
    #[serde(default)]
    candidates: Vec<WindowCandidate>,
    #[serde(default)]
    links: LinkContext,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CascadeRequest {
    #[serde(default)]
    explicit: Option<String>,
    #[serde(default)]
    tab_profile: Option<String>,
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default)]
    room: Option<String>,
    #[serde(default)]
    known: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BadgeRequest {
    #[serde(default)]
    tab_profile: Option<String>,
    workspace_effective: String,
}

#[derive(Deserialize)]
struct IdRequest {
    #[serde(default)]
    id: Option<String>,
}

#[derive(Deserialize)]
struct ProfileRequest {
    profile: BrowserProfileId,
}

#[derive(Deserialize)]
struct RecordRequest {
    record: ProfileRecord,
}

#[derive(Deserialize)]
struct ProxyRequest {
    proxy: ProfileProxy,
}

#[derive(Deserialize)]
struct NameRequest {
    name: String,
}

#[derive(Deserialize)]
struct ColorRequest {
    #[serde(default)]
    color: Option<String>,
}

#[derive(Deserialize)]
struct IconRequest {
    #[serde(default)]
    icon: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BookRequest {
    #[serde(default)]
    book: Value,
    #[serde(default)]
    default_name: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    edit: Option<BookEdit>,
}

/// One edit of a [`ProfileBook`], named as the Swift method it ports.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum BookEdit {
    Create {
        id: String,
        name: String,
        #[serde(default)]
        color: Option<String>,
        #[serde(default)]
        icon: Option<String>,
        #[serde(default)]
        source: Option<BTreeMap<String, String>>,
    },
    Rename {
        id: String,
        name: String,
    },
    SetColor {
        id: String,
        #[serde(default)]
        color: Option<String>,
    },
    SetIcon {
        id: String,
        #[serde(default)]
        icon: Option<String>,
    },
    Move {
        id: String,
        index: i64,
    },
    Delete {
        id: String,
    },
    MarkDeleted {
        id: String,
    },
    FinishCleanup {
        ids: Vec<String>,
    },
    RequireReusable {
        id: String,
    },
}

#[derive(Deserialize)]
struct DirectoriesRequest {
    id: String,
    #[serde(default)]
    names: Vec<String>,
}

#[derive(Deserialize)]
struct ClaimRequest {
    #[serde(default)]
    claims: CleanupClaims,
    #[serde(default)]
    pending: Vec<String>,
    #[serde(default)]
    open: BTreeSet<BrowserProfileId>,
    #[serde(default)]
    ids: Vec<String>,
}

#[derive(Deserialize)]
struct OffTheRecordRequest {
    #[serde(default)]
    state: OffTheRecordProfiles,
    profile: BrowserProfileId,
}

/// `{ok: value}` for an accepted value, `{error: reason}` for a refused one.
fn checked<T: serde::Serialize>(result: Result<T, ProfileBookError>) -> Value {
    match result {
        Ok(value) => json!({"ok": value}),
        Err(error) => json!({"error": error}),
    }
}

fn read_book(book: Value, default_name: Option<&str>) -> Result<ProfileBook, OpError> {
    let book = if book.is_null() { json!({}) } else { book };
    ProfileBook::from_json(book, default_name.unwrap_or(DEFAULT_NAME))
        .map_err(|error| OpError::Invalid(error.to_string()))
}

/// The default profile's name when a request names none (the Swift string's English value).
const DEFAULT_NAME: &str = "Default";

fn edit_book(
    book: &mut ProfileBook,
    edit: BookEdit,
) -> Result<Option<ProfileRecord>, ProfileBookError> {
    match edit {
        BookEdit::Create { id, name, color, icon, source } => {
            book.create(&id, &name, color.as_deref(), icon.as_deref(), source).map(Some)
        }
        BookEdit::Rename { id, name } => book.rename(&id, &name).map(|()| None),
        BookEdit::SetColor { id, color } => book.set_color(&id, color.as_deref()).map(|()| None),
        BookEdit::SetIcon { id, icon } => book.set_icon(&id, icon.as_deref()).map(|()| None),
        BookEdit::Move { id, index } => book.move_to(&id, index).map(|()| None),
        BookEdit::Delete { id } => book.delete(&id).map(|()| None),
        BookEdit::MarkDeleted { id } => {
            book.mark_deleted(&id);
            Ok(None)
        }
        BookEdit::FinishCleanup { ids } => {
            book.finish_cleanup(&ids);
            Ok(None)
        }
        BookEdit::RequireReusable { id } => book.require_reusable(&id).map(|()| None),
    }
}

fn profile_op(op: &str, request: Value) -> Result<Value, OpError> {
    match op {
        "browser_rules_profile_resolve" => {
            let CascadeRequest { explicit, workspace, room, known, .. } = parse(request)?;
            Ok(json!(profiles::resolve(
                explicit.as_deref(),
                workspace.as_deref(),
                room.as_deref(),
                |id| known.contains(id),
            )))
        }
        "browser_rules_profile_source" => {
            let CascadeRequest { tab_profile, workspace, room, known, .. } = parse(request)?;
            Ok(encode(&profiles::source(
                tab_profile.as_deref(),
                workspace.as_deref(),
                room.as_deref(),
                |id| known.contains(id),
            )))
        }
        "browser_rules_profile_shows_tab_badge" => {
            let BadgeRequest { tab_profile, workspace_effective } = parse(request)?;
            Ok(json!(profiles::shows_tab_badge(tab_profile.as_deref(), &workspace_effective)))
        }
        "browser_rules_profile_is_valid_id" => {
            let IdRequest { id } = parse(request)?;
            Ok(json!(id.is_some_and(|id| profiles::is_valid_id(&id))))
        }
        "browser_rules_profile_engine_profile" => {
            let IdRequest { id } = parse(request)?;
            Ok(encode(&profiles::engine_profile(id.as_deref())))
        }
        "browser_rules_profile_wire_id" => {
            let ProfileRequest { profile } = parse(request)?;
            Ok(json!(profiles::wire_id(&profile)))
        }
        "browser_rules_profile_monogram" => {
            let RecordRequest { record } = parse(request)?;
            Ok(json!(record.monogram()))
        }
        "browser_rules_profile_proxy" => {
            let ProxyRequest { proxy } = parse(request)?;
            Ok(json!({
                "chromiumServer": proxy.chromium_server(),
                "chromiumBypassList": proxy.chromium_bypass_list(),
                "webKitPort": proxy.webkit_port(),
                "webKitExcludedDomains": proxy.webkit_excluded_domains(),
            }))
        }
        "browser_rules_profile_valid_name" => {
            let NameRequest { name } = parse(request)?;
            Ok(checked(profiles::valid_name(&name)))
        }
        "browser_rules_profile_valid_color" => {
            let ColorRequest { color } = parse(request)?;
            Ok(checked(profiles::valid_color(color.as_deref())))
        }
        "browser_rules_profile_valid_icon" => {
            let IconRequest { icon } = parse(request)?;
            Ok(checked(profiles::valid_icon(icon.as_deref())))
        }
        "browser_rules_profile_book_read" => {
            let BookRequest { book, default_name, .. } = parse(request)?;
            Ok(encode(&read_book(book, default_name.as_deref())?))
        }
        "browser_rules_profile_book_ordered" => {
            let BookRequest { book, default_name, .. } = parse(request)?;
            Ok(encode(&read_book(book, default_name.as_deref())?.ordered()))
        }
        "browser_rules_profile_book_engine_profile" => {
            let BookRequest { book, default_name, id, .. } = parse(request)?;
            Ok(encode(&read_book(book, default_name.as_deref())?.engine_profile(id.as_deref())))
        }
        "browser_rules_profile_book_edit" => {
            let BookRequest { book, default_name, edit, .. } = parse(request)?;
            let edit = edit.ok_or_else(|| OpError::Invalid("edit is required".into()))?;
            let mut book = read_book(book, default_name.as_deref())?;
            Ok(match edit_book(&mut book, edit) {
                Ok(record) => json!({"book": book, "record": record}),
                Err(error) => json!({"error": error}),
            })
        }
        "browser_rules_profile_chromium_directories" => {
            let DirectoriesRequest { id, names } = parse(request)?;
            Ok(json!(profiles::chromium_directories(&id, &names)))
        }
        "browser_rules_profile_cleanup_claim" => {
            let ClaimRequest { mut claims, pending, open, .. } = parse(request)?;
            let ready = claims.claim(&pending, |profile| open.contains(profile));
            Ok(json!({"claims": claims, "ready": ready}))
        }
        "browser_rules_profile_cleanup_release" => {
            let ClaimRequest { mut claims, ids, .. } = parse(request)?;
            claims.release(&ids);
            Ok(encode(&claims))
        }
        "browser_rules_profile_off_the_record_begin" => {
            let OffTheRecordRequest { mut state, profile } = parse(request)?;
            state.begin(profile);
            Ok(encode(&state))
        }
        "browser_rules_profile_off_the_record_end" => {
            let OffTheRecordRequest { mut state, profile } = parse(request)?;
            let ended = state.end(&profile);
            Ok(json!({"state": state, "ended": ended}))
        }
        "browser_rules_profile_off_the_record_is" => {
            let OffTheRecordRequest { state, profile } = parse(request)?;
            Ok(json!({
                "active": state.contains(&profile),
                "offTheRecord": state.is_off_the_record(&profile),
            }))
        }
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// True for the ops [`call`] answers.
pub fn serves(op: &str) -> bool {
    op.starts_with("browser_rules_")
}

/// Runs `op` on `request` (a JSON object; null means `{}`).
pub fn call(op: &str, request: Value) -> Result<Value, OpError> {
    let request = if request.is_null() { json!({}) } else { request };
    match op {
        "browser_rules_is_top_level_domain" => {
            let TldRequest { label, labels } = parse(request)?;
            match (label, labels) {
                (Some(label), None) => Ok(json!(address::is_top_level_domain(&label))),
                (None, Some(labels)) => Ok(json!(
                    labels
                        .iter()
                        .map(|label| address::is_top_level_domain(label))
                        .collect::<Vec<_>>()
                )),
                _ => Err(OpError::Invalid("one of label or labels".into())),
            }
        }
        "browser_rules_host_typo_fix" => {
            let TextRequest { text } = parse(request)?;
            Ok(encode(&address::fix_host_typo(&text)))
        }
        "browser_rules_https_upgrade_falls_back" => {
            let LoadErrorRequest { domain, code } = parse(request)?;
            Ok(json!(address::https_upgrade_falls_back(&domain, code)))
        }
        "browser_rules_calculator_answer" => {
            let TextRequest { text } = parse(request)?;
            Ok(json!(calculator::answer(&text)))
        }
        "browser_rules_link_gesture" => {
            let GestureRequest { modifiers, button } = parse(request)?;
            Ok(encode(&Gesture::of(modifiers, button)))
        }
        "browser_rules_link_action" => {
            let ActionRequest { mapping, gesture } = parse(request)?;
            Ok(encode(&mapping.action(gesture)))
        }
        "browser_rules_webkit_link_click" => {
            let WebKitClickRequest { modifiers, button, mapping } = parse(request)?;
            let click: WebKitLinkClick = links::webkit_link_click(modifiers, button, &mapping);
            Ok(encode(&click))
        }
        "browser_rules_cef_link_placement" => {
            let CefPlacementRequest { disposition, user_gesture, click, now, mapping } =
                parse(request)?;
            let placement: LinkPlacement =
                links::cef_placement(disposition, user_gesture, click, now, &mapping);
            Ok(encode(&placement))
        }
        "browser_rules_window_placement" => {
            let WindowOpRequest { request, links, .. } = parse(request)?;
            Ok(encode(&links::window_placement(&request, &links)))
        }
        "browser_rules_window_decide" => {
            let WindowOpRequest { request, candidates, links } = parse(request)?;
            let decision: WindowDecision = links::decide_window(&request, &candidates, &links);
            Ok(encode(&decision))
        }
        other if other.starts_with("browser_rules_profile_") => profile_op(other, request),
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}
