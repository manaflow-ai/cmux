//! Screen Sharing's action rules (`CmuxNextMacScreen/MacScreenActions.swift`), as data. See `ui/mod.rs`.
//! Strings stay in Swift: a refusal answers its key and the values it names (`listed` devices as
//! `{id, name}`, which Swift sorts and joins with its `ListFormatter`).
//!
//! - `actions.normalizedDeviceId` `{text}` → the hub id (lowercased UUID) or null
//!   (`MacScreenRecord.normalizedDeviceID`).
//! - `actions.deviceId` `{text, devices: [Device]}` → `{id}` or
//!   `{failure: {key, name?, listed: [{id, name}]}}` (`MacScreenActions.deviceID(named:among:)`).
//! - `actions.missingDevice` `{devices}` → `{key, listed}` (no `device`, or not a string).
//! - `actions.unlistedName` `{device: Value?, devices}` → the name or null.
//! - `actions.noScreen` `{name, listed: [{name, noScreenReason?}]}` → `{name, reasonKey}` or null.
//! - `actions.listedDevice` `{name, screenAction?, reason?}` → `{name, noScreenReason?}` or null.
//! - `actions.noScreenReasonKey` `{noScreenReason?}` → the clause's key.
//! - `actions.scope` `{scope: Value?}` → `"full"` or `"view"`.
//! - `actions.autoconnects` `{autoconnect: Value?}` → bool; `actions.mayAutoconnect` adds
//!   `onlyPersonStartsViewing`.
//! - `actions.openPlan` `{hasDevice, isPerson, ownDevice, autoconnect, onlyPersonStartsViewing, scope}`
//!   → `{requesting: "view"|"full"|null, startedBy: bool}` (`record`'s branches after the id).
//! - `actions.stopSharing` `{workerRunning, hubHasSession}` → `{unavailable, run: "hub"|"worker"|"refuse"}`.
//! - `actions.refusal` `{notFound, unlisted}` → `"notFound"|"refused"|"waitListed"` (`refused(_:_:)`).
//! - `actions.openTarget` `{kind?}` → bool: Open takes no target but a pane or tab (`noPane` refusal key).
//! - `actions.screenTabId` `{targetKind?, targetId?, selected?}` → the tab id or null (`screenTab`).
//! - `actions.isViewer` `{pending, streaming}` → bool (`viewer`: asks, waits or streams).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, a: &Value) -> Answer {
    Some(match name {
        "normalizedDeviceId" => {
            args::<TextArgs>(a).and_then(|t| answer(&normalized_device_id(&t.text)))
        }
        "deviceId" => args::<DeviceIdArgs>(a).map(|d| device_id_answer(&d.text, &d.devices)),
        "missingDevice" => args::<DevicesArgs>(a).and_then(|d| answer(&missing_device(&d.devices))),
        "unlistedName" => args::<UnlistedArgs>(a)
            .and_then(|u| answer(&unlisted_name(u.device.as_ref(), &u.devices))),
        "noScreen" => args::<NoScreenArgs>(a).and_then(|n| answer(&no_screen(&n.name, &n.listed))),
        "listedDevice" => args::<ListedArgs>(a).and_then(|l| {
            answer(&listed_device(&l.name, l.screen_action.as_deref(), l.reason.as_deref()))
        }),
        "noScreenReasonKey" => args::<ListedDevice>(a)
            .and_then(|l| answer(&no_screen_reason_key(l.no_screen_reason.as_deref()))),
        "scope" => args::<ScopeArgs>(a).and_then(|s| answer(&scope(s.scope.as_ref()))),
        "autoconnects" => {
            args::<AutoArgs>(a).and_then(|s| answer(&autoconnects(s.autoconnect.as_ref())))
        }
        "mayAutoconnect" => args::<AutoArgs>(a).and_then(|s| {
            answer(&(autoconnects(s.autoconnect.as_ref()) && !s.only_person_starts_viewing))
        }),
        "openPlan" => args::<OpenPlanArgs>(a).and_then(|p| answer(&open_plan(&p))),
        "stopSharing" => args::<StopArgs>(a).and_then(|s| answer(&stop_sharing(&s))),
        "refusal" => args::<RefusalArgs>(a).and_then(|r| answer(&refusal(&r))),
        "openTarget" => args::<KindArgs>(a).and_then(|k| answer(&open_target(k.kind.as_deref()))),
        "screenTabId" => args::<ScreenTabArgs>(a).and_then(|s| answer(&screen_tab_id(&s))),
        "isViewer" => args::<ViewerArgs>(a).and_then(|v| answer(&(v.pending || v.streaming))),
        _ => return None,
    })
}

// MARK: Devices

/// A hub device as the home page lists it (`HubDevice`: id, name, online, Allow Mac Screen).
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Device {
    pub id: String,
    pub name: String,
    pub online: bool,
    pub mac_screen_shared: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub(crate) struct Listed {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub(crate) struct Failure {
    pub key: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub listed: Vec<Listed>,
}

#[derive(Deserialize)]
struct TextArgs {
    text: String,
}

#[derive(Deserialize)]
struct DeviceIdArgs {
    text: String,
    #[serde(default)]
    devices: Vec<Device>,
}

#[derive(Deserialize)]
struct DevicesArgs {
    #[serde(default)]
    devices: Vec<Device>,
}

#[derive(Deserialize)]
struct UnlistedArgs {
    #[serde(default)]
    device: Option<Value>,
    #[serde(default)]
    devices: Vec<Device>,
}

fn listed(devices: &[&Device]) -> Vec<Listed> {
    devices.iter().map(|d| Listed { id: d.id.clone(), name: d.name.clone() }).collect()
}

/// A UUID as Foundation's `UUID(uuidString:)` reads it (8-4-4-4-12 hex, either case), after trimming
/// spaces and tabs, as its lowercased string.
pub(crate) fn normalized_device_id(text: &str) -> Option<String> {
    let text = text.trim_matches(|c: char| c == ' ' || c == '\t');
    let groups: Vec<&str> = text.split('-').collect();
    let lens = [8, 4, 4, 4, 12];
    if groups.len() != 5 {
        return None;
    }
    for (group, len) in groups.iter().zip(lens) {
        if group.len() != len || !group.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
    }
    Some(text.to_ascii_lowercase())
}

/// The hub id `text` names: an id as is, else the one device whose name matches folded (case,
/// diacritics, width), else as a slug (punctuation and spacing too). Several matches with exactly one
/// online and sharing pick that one.
pub(crate) fn device_id(text: &str, devices: &[Device]) -> Result<String, Failure> {
    if let Some(id) = normalized_device_id(text) {
        return Ok(id);
    }
    let mut name = text.trim();
    // A `cmux device list` row id (`peer:desk-1`) names the machine.
    if let Some(rest) = name.strip_prefix("peer:") {
        name = rest;
    }
    if name.is_empty() {
        return Err(missing_device(devices));
    }
    for key in [folded as fn(&str) -> String, slug] {
        let wanted = key(name);
        if wanted.is_empty() {
            continue;
        }
        let matches: Vec<&Device> = devices.iter().filter(|d| key(&d.name) == wanted).collect();
        if matches.len() == 1 {
            return Ok(matches[0].id.clone());
        }
        let live: Vec<&&Device> =
            matches.iter().filter(|d| d.online && d.mac_screen_shared).collect();
        if matches.len() > 1 && live.len() == 1 {
            return Ok(live[0].id.clone());
        }
        if matches.len() > 1 {
            return Err(Failure {
                key: "macScreen.actions.ambiguousDevice",
                name: Some(name.to_string()),
                listed: listed(&matches),
            });
        }
    }
    Err(unknown_device(name, devices))
}

fn device_id_answer(text: &str, devices: &[Device]) -> Value {
    match device_id(text, devices) {
        Ok(id) => json!({ "id": id }),
        Err(failure) => json!({ "failure": failure }),
    }
}

fn unknown_device(name: &str, devices: &[Device]) -> Failure {
    let key = if devices.is_empty() {
        "macScreen.actions.unknownDeviceNoneListed"
    } else {
        "macScreen.actions.unknownDevice"
    };
    Failure {
        key,
        name: Some(name.to_string()),
        listed: listed(&devices.iter().collect::<Vec<_>>()),
    }
}

pub(crate) fn missing_device(devices: &[Device]) -> Failure {
    let key = if devices.is_empty() {
        "macScreen.actions.missingDeviceNoneListed"
    } else {
        "macScreen.actions.missingDevice"
    };
    Failure { key, name: None, listed: listed(&devices.iter().collect::<Vec<_>>()) }
}

/// The `device` of an invocation when it is a name (not an id) none of `devices` answers to.
pub(crate) fn unlisted_name(device: Option<&Value>, devices: &[Device]) -> Option<String> {
    let text = device?.as_str()?;
    if normalized_device_id(text).is_some() {
        return None;
    }
    let name = text.trim();
    if name.is_empty() || devices.iter().any(|d| same_name(&d.name, name)) {
        return None;
    }
    Some(name.to_string())
}

fn same_name(candidate: &str, name: &str) -> bool {
    [folded as fn(&str) -> String, slug].iter().any(|key| {
        let wanted = key(name);
        !wanted.is_empty() && key(candidate) == wanted
    })
}

/// Foundation's `folding([.caseInsensitive, .diacriticInsensitive, .widthInsensitive])` for the
/// names a device carries: lowercase, Latin letters without their marks, full-width ASCII as ASCII.
pub(crate) fn folded(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.trim().chars() {
        let c = unwiden(c);
        if is_combining_mark(c) {
            continue;
        }
        for lower in c.to_lowercase() {
            match strip_mark(lower) {
                Some(base) => out.push_str(base),
                None => out.push(lower),
            }
        }
    }
    out
}

/// `folded`, then its runs of letters and digits joined by `-` ("Leo’s Mac" → `leo-s-mac`).
pub(crate) fn slug(name: &str) -> String {
    folded(name)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

fn unwiden(c: char) -> char {
    match c as u32 {
        0xFF01..=0xFF5E => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        0x3000 => ' ',
        _ => c,
    }
}

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// A lowercase Latin letter with a mark, as its base letter(s).
fn strip_mark(c: char) -> Option<&'static str> {
    Some(match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => "c",
        'ď' | 'đ' => "d",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => "g",
        'ĥ' | 'ħ' => "h",
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ı' => "i",
        'ĵ' => "j",
        'ķ' => "k",
        'ĺ' | 'ļ' | 'ľ' | 'ŀ' | 'ł' => "l",
        'ñ' | 'ń' | 'ņ' | 'ň' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ŏ' | 'ő' => "o",
        'ŕ' | 'ŗ' | 'ř' => "r",
        'ś' | 'ŝ' | 'ş' | 'š' => "s",
        'ţ' | 'ť' | 'ŧ' => "t",
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => "u",
        'ŵ' => "w",
        'ý' | 'ÿ' | 'ŷ' => "y",
        'ź' | 'ż' | 'ž' => "z",
        _ => return None,
    })
}

// MARK: Machines `cmux device list` lists

/// A machine `cmux device list` lists (`MacScreenListedDevice`).
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct ListedDevice {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub no_screen_reason: Option<String>,
}

#[derive(Deserialize)]
struct NoScreenArgs {
    name: String,
    #[serde(default)]
    listed: Vec<ListedDevice>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListedArgs {
    name: String,
    #[serde(default)]
    screen_action: Option<String>,
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NoScreen {
    pub name: String,
    pub reason_key: &'static str,
}

/// "<name> offers no screen: <reason>." for the machine among `listed` that `name` names
/// (`macScreen.actions.offersNoScreen` with `name` and the reason's key).
pub(crate) fn no_screen(name: &str, listed: &[ListedDevice]) -> Option<NoScreen> {
    let device = listed
        .iter()
        .find(|d| same_name(&d.name, name))
        .or_else(|| listed.iter().find(|d| d.name == name))?;
    Some(NoScreen {
        name: device.name.clone(),
        reason_key: no_screen_reason_key(device.no_screen_reason.as_deref()),
    })
}

/// A `cmux device list` row by its `screen` offer: none for a row with no offer (a login).
pub(crate) fn listed_device(
    name: &str,
    screen_action: Option<&str>,
    reason: Option<&str>,
) -> Option<ListedDevice> {
    let action = screen_action?;
    Some(ListedDevice {
        name: name.to_string(),
        no_screen_reason: (action == "none").then(|| reason.unwrap_or("unknown").to_string()),
    })
}

/// The clause after "offers no screen: ".
pub(crate) fn no_screen_reason_key(reason: Option<&str>) -> &'static str {
    match reason {
        Some("offline") => "macScreen.actions.refusal.noScreen.offline",
        Some("no-desktop") => "macScreen.actions.refusal.noScreen.noDesktop",
        Some("phone") => "macScreen.actions.refusal.noScreen.phone",
        None => "macScreen.actions.refusal.noScreen.notRegistered",
        Some(_) => "macScreen.actions.refusal.noScreen.unknown",
    }
}

// MARK: Opening

#[derive(Deserialize)]
struct ScopeArgs {
    #[serde(default)]
    scope: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AutoArgs {
    #[serde(default)]
    autoconnect: Option<Value>,
    #[serde(default)]
    only_person_starts_viewing: bool,
}

/// `scope`: `full` asks for Full Control; anything else View Only.
pub(crate) fn scope(value: Option<&Value>) -> &'static str {
    match value.and_then(Value::as_str) {
        Some(s) if s.to_lowercase() == "full" => "full",
        _ => "view",
    }
}

/// `autoconnect: true`, or `"true"` in any case.
pub(crate) fn autoconnects(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s.to_lowercase() == "true",
        _ => false,
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct OpenPlanArgs {
    pub has_device: bool,
    pub is_person: bool,
    pub own_device: bool,
    pub autoconnect: Option<Value>,
    pub only_person_starts_viewing: bool,
    pub scope: Option<Value>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OpenPlan {
    /// The scope the record asks for at once; null waits at Connect (or opens the home page).
    pub requesting: Option<&'static str>,
    /// The tab names the agent that started it.
    pub started_by: bool,
}

/// `record`'s branches once the device resolved: a person asks for View Only; an agent on one of
/// the person's own devices for `scope`; an autoconnecting one View Only; any other waits.
pub(crate) fn open_plan(p: &OpenPlanArgs) -> OpenPlan {
    if !p.has_device {
        return OpenPlan { requesting: None, started_by: false };
    }
    if p.is_person {
        return OpenPlan { requesting: Some("view"), started_by: false };
    }
    let may_autoconnect = autoconnects(p.autoconnect.as_ref()) && !p.only_person_starts_viewing;
    if !(p.own_device || may_autoconnect) {
        return OpenPlan { requesting: None, started_by: false };
    }
    let requesting = if p.own_device { scope(p.scope.as_ref()) } else { "view" };
    OpenPlan { requesting: Some(requesting), started_by: true }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StopArgs {
    #[serde(default)]
    worker_running: bool,
    #[serde(default)]
    hub_has_session: bool,
}

#[derive(Debug, Serialize, PartialEq)]
pub(crate) struct StopSharing {
    /// The row shows the hub's no-session reason (unavailable).
    pub unavailable: bool,
    pub run: &'static str,
}

/// Stop Sharing This Mac: the app's own host while it has a session, else cmux Remote's worker.
fn stop_sharing(s: &StopArgs) -> StopSharing {
    let run = if s.hub_has_session {
        "hub"
    } else if s.worker_running {
        "worker"
    } else {
        "refuse"
    };
    StopSharing { unavailable: !s.worker_running && !s.hub_has_session, run }
}

#[derive(Deserialize)]
struct RefusalArgs {
    #[serde(default, rename = "notFound")]
    not_found: bool,
    #[serde(default)]
    unlisted: bool,
}

/// A failed open's answer: a `not_found` target goes to the app's refusal (the run answers done);
/// a name Screen Sharing does not list waits for `cmux device list`; else refused with the message.
fn refusal(r: &RefusalArgs) -> &'static str {
    if r.not_found {
        "notFound"
    } else if r.unlisted {
        "waitListed"
    } else {
        "refused"
    }
}

#[derive(Deserialize)]
struct KindArgs {
    #[serde(default)]
    kind: Option<String>,
}

/// Open accepts no target, or a pane or tab; any other refuses with `macScreen.actions.noPane`.
fn open_target(kind: Option<&str>) -> bool {
    matches!(kind, None | Some("pane") | Some("tab"))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenTabArgs {
    #[serde(default)]
    target_kind: Option<String>,
    #[serde(default)]
    target_id: Option<String>,
    #[serde(default)]
    selected: Option<String>,
}

/// The targeted tab, else the selected one; a target that is not a tab names none.
fn screen_tab_id(s: &ScreenTabArgs) -> Option<String> {
    match s.target_kind.as_deref() {
        Some("tab") => s.target_id.clone(),
        Some(_) => None,
        None => s.selected.clone(),
    }
}

#[derive(Deserialize)]
struct ViewerArgs {
    #[serde(default)]
    pending: bool,
    #[serde(default)]
    streaming: bool,
}

#[cfg(test)]
#[path = "actions_tests.rs"]
mod tests;
