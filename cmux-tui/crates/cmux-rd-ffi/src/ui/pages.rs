//! The Mac Screen pages' rules (`MacScreenPages.swift`): a tab's route and the record it names, a
//! restored tab's title, what opening a tab confirms and starts, where a pushed ticket goes, and the
//! scope a new device screen resumes with. Swift keeps the tabs, the hub and the views and runs the
//! answers. See `ui/mod.rs`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, raw: &Value) -> Answer {
    Some(match name {
        "route" => args::<Record>(raw).and_then(|a| answer(&route(&a))),
        "parseRoute" => args::<RouteArgs>(raw).and_then(|a| answer(&parse_route(&a.route))),
        "titleForRoute" => {
            args::<TitleArgs>(raw).and_then(|a| answer(&title_for_route(a.route.as_deref())))
        }
        "normalizedDeviceId" => {
            args::<TextArgs>(raw).and_then(|a| answer(&normalized_device_id(&a.text)))
        }
        "normalizedName" => args::<TextArgs>(raw).and_then(|a| answer(&normalized_name(&a.text))),
        "displayId" => args::<TextArgs>(raw).and_then(|a| answer(&display_id(&a.text))),
        "prepare" => args::<PrepareArgs>(raw).and_then(|a| answer(&prepare(&a))),
        "startConnecting" => args::<ConnectArgs>(raw).and_then(|a| answer(&start_connecting(&a))),
        "connectInBackground" => {
            args::<ConnectArgs>(raw).and_then(|a| answer(&connect_in_background(&a)))
        }
        "ticketTarget" => args::<TicketArgs>(raw).and_then(|a| answer(&ticket_target(&a))),
        "openPushed" => args::<PushedArgs>(raw).and_then(|a| answer(&open_pushed(&a))),
        "hostSharingChanged" => {
            args::<SharingArgs>(raw).and_then(|a| answer(&host_sharing_changed(&a)))
        }
        "resumeScope" => args::<ResumeArgs>(raw).and_then(|a| answer(&resume_scope(&a))),
        _ => return None,
    })
}

// MARK: Records and routes

/// `MacScreenRecord`'s fields: a device's (with a run link's display, control and name), an old link
/// record's `macId`, or neither: home.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display: Option<u32>,
    #[serde(default)]
    pub control: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// An old pairing-link record's Mac (its UUID as Swift writes it, uppercase).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac_id: Option<String>,
}

impl Record {
    /// `MacScreenRecord(deviceID:display:control:name:)`: the id and name normalized.
    pub(crate) fn device(
        id: &str,
        display: Option<u32>,
        control: bool,
        name: Option<&str>,
    ) -> Self {
        Self {
            device_id: normalized_device_id(id),
            display,
            control,
            name: name.and_then(normalized_name),
            mac_id: None,
        }
    }
}

#[derive(Deserialize)]
struct TextArgs {
    text: String,
}

/// `UUID(uuidString:)`: 8-4-4-4-12 hex digits.
fn uuid(text: &str) -> Option<String> {
    let groups: Vec<&str> = text.split('-').collect();
    let lengths = [8, 4, 4, 4, 12];
    let ok = groups.len() == 5
        && groups
            .iter()
            .zip(lengths)
            .all(|(g, n)| g.len() == n && g.chars().all(|c| c.is_ascii_hexdigit()));
    ok.then(|| text.to_string())
}

/// A device id as the hub writes it (a lowercase UUID; spaces and tabs around it go); nil for anything else.
pub(crate) fn normalized_device_id(text: &str) -> Option<String> {
    uuid(text.trim_matches([' ', '\t'])).map(|id| id.to_lowercase())
}

/// A CGDirectDisplayID as a link writes it (decimal, nonzero); nil for anything else.
pub(crate) fn display_id(text: &str) -> Option<u32> {
    if text.is_empty() || !text.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    text.parse::<u32>().ok().filter(|id| *id != 0)
}

/// A run's name as a label: one line, trimmed, at most 80 characters; nil when empty.
pub(crate) fn normalized_name(text: &str) -> Option<String> {
    let newline = |c: char| {
        matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    };
    let line = text.split(newline).collect::<Vec<_>>().join(" ");
    let line = line.trim_matches([' ', '\t']);
    (!line.is_empty()).then(|| line.chars().take(80).collect())
}

/// What a query value keeps unencoded: `urlQueryAllowed` but the characters that split or change it (`&=+#`).
fn value_allowed(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"!$'()*,-./:;?@_~".contains(&b)
}

fn percent_encode(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        if value_allowed(b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[i] == b'%'
            && let (Some(Some(h)), Some(Some(l))) =
                (bytes.get(i + 1).map(|b| hex(*b)), bytes.get(i + 2).map(|b| hex(*b)))
        {
            out.push((h * 16 + l) as u8);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// What tab shows, kept as its page tab route: "home", "device:<id>" (a run's link adds
/// `?display=<n>&control=1&name=<run>`), or an old link record's "mac:<UUID>".
fn route(record: &Record) -> String {
    if let Some(device) = &record.device_id {
        let mut query = Vec::new();
        if let Some(display) = record.display {
            query.push(format!("display={display}"));
        }
        if record.control {
            query.push("control=1".into());
        }
        if let Some(name) = &record.name {
            query.push(format!("name={}", percent_encode(name)));
        }
        return if query.is_empty() {
            format!("device:{device}")
        } else {
            format!("device:{device}?{}", query.join("&"))
        };
    }
    record.mac_id.as_ref().map_or_else(|| "home".into(), |mac| format!("mac:{mac}"))
}

#[derive(Deserialize)]
struct RouteArgs {
    route: String,
}

/// The record a route names (home is the empty record); nil for anything else. A device's query
/// keeps only what parses: a bad display reads as none.
pub(crate) fn parse_route(route: &str) -> Option<Record> {
    if route == "home" {
        return Some(Record::default());
    }
    if let Some(rest) = route.strip_prefix("device:") {
        let (id, query) = match rest.split_once('?') {
            Some((id, query)) => (id, Some(query)),
            None => (rest, None),
        };
        normalized_device_id(id)?;
        let Some(query) = query else { return Some(Record::device(id, None, false, None)) };
        let items: Vec<(String, String)> = query
            .split('&')
            .map(|item| match item.split_once('=') {
                Some((k, v)) => (percent_decode(k), percent_decode(v)),
                None => (percent_decode(item), String::new()),
            })
            .collect();
        let value = |name: &str| items.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str());
        return Some(Record::device(
            id,
            value("display").and_then(display_id),
            value("control") == Some("1"),
            value("name"),
        ));
    }
    let mac = route.strip_prefix("mac:").and_then(uuid)?;
    Some(Record { mac_id: Some(mac.to_uppercase()), ..Record::default() })
}

#[derive(Deserialize)]
struct TitleArgs {
    route: Option<String>,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct RouteTitle {
    /// "home" (`macScreen.tab.homeTitle`) or "device" (the device's name, else `macScreen.hub.unknownDevice`).
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    device_id: Option<String>,
}

/// A tab known only by its route: the device's name, else "Screen Sharing"; nil for no route.
fn title_for_route(route: Option<&str>) -> Option<RouteTitle> {
    let route = route?;
    let device_id = parse_route(route).and_then(|r| r.device_id);
    Some(match device_id {
        Some(id) => RouteTitle { kind: "device", device_id: Some(id) },
        None => RouteTitle { kind: "home", device_id: None },
    })
}

// MARK: Opening tabs

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrepareArgs {
    by_person: bool,
    /// An agent's start waits for this record's device (`pendingStarters`).
    has_pending_starter: bool,
    /// A scope waits for this record's device (`pendingScopes`).
    has_pending_scope: bool,
    is_run_link: bool,
    /// The tab's view is made.
    has_tab: bool,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Prepare {
    /// Keep the pending starter as the tab's (a person's open drops it; Swift removes it either way).
    keep_starter: bool,
    /// The record is confirmed (connects without asking).
    confirm: bool,
    /// Move the device's pending scope to the tab.
    move_scope: bool,
    run_link: bool,
    /// Make the view now: an agent started it, so it asks the hub even unseen.
    make_view: bool,
}

/// A person's open, or an agent's start on the person's own device, is confirmed; the agent's makes its view now.
fn prepare(a: &PrepareArgs) -> Prepare {
    let starts = a.by_person || a.has_pending_starter;
    let keep_starter = !a.by_person && a.has_pending_starter;
    Prepare {
        keep_starter,
        confirm: starts,
        move_scope: starts && a.has_pending_scope,
        run_link: a.is_run_link,
        make_view: keep_starter && !a.has_tab,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectArgs {
    /// The tab has a record, of a device.
    is_device: bool,
    /// Its confirmed record is the record now.
    confirmed: bool,
    #[serde(default)]
    has_pending_scope: bool,
    #[serde(default)]
    has_tab: bool,
}

/// A confirmed device tab asks the hub now (Swift makes its view and starts the pane).
fn start_connecting(a: &ConnectArgs) -> bool {
    a.is_device && a.confirmed
}

/// An unselected tab connects unseen only with a scope waiting or its view made.
fn connect_in_background(a: &ConnectArgs) -> bool {
    start_connecting(a) && (a.has_pending_scope || a.has_tab)
}

// MARK: Pushed tickets

/// A device tab's viewer, as the pages see it.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HubTab {
    key: String,
    device_id: String,
    /// `phase.sessionID`.
    session_id: Option<String>,
    /// The session this tab's share moved away from.
    moved_session: Option<String>,
    #[serde(default)]
    pending: bool,
    #[serde(default)]
    streaming: bool,
    /// `accepts(ticket)`: this tab asked this host and waits for its answer.
    #[serde(default)]
    accepts: bool,
}

/// The tabs in key order, as `hubTabs` lists them.
fn sorted(tabs: &[HubTab]) -> Vec<&HubTab> {
    let mut tabs: Vec<&HubTab> = tabs.iter().collect();
    tabs.sort_by(|a, b| a.key.cmp(&b.key));
    tabs
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TicketArgs {
    session_id: String,
    pushed: bool,
    tabs: Vec<HubTab>,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Target {
    /// "accept" (the tab at `key`), "openPushed" (no tab asked) or "none".
    action: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    key: Option<String>,
}

/// A viewer ticket goes to the tab whose session it names, else the tab that asked its host; a pushed
/// one no tab asked for opens (``openPushed``).
fn ticket_target(a: &TicketArgs) -> Target {
    let tabs = sorted(&a.tabs);
    let target = tabs
        .iter()
        .find(|t| t.session_id.as_deref() == Some(a.session_id.as_str()))
        .or_else(|| tabs.iter().find(|t| t.accepts));
    match target {
        Some(t) => Target { action: "accept", key: Some(t.key.clone()) },
        None if a.pushed => Target { action: "openPushed", key: None },
        None => Target { action: "none", key: None },
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PushedArgs {
    /// The ticket's peer.
    device_id: String,
    moved_from: Option<String>,
    tabs: Vec<HubTab>,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Pushed {
    /// "drop" (not a device id), "acceptPushed" (the moved tab, same host, switches in place),
    /// "replace" (the tab at `key` gives its place to the device's new tab) or "open" (a new tab).
    /// For "replace" and "open" Swift keeps the ticket for the device first.
    action: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    key: Option<String>,
}

/// A ticket no tab asked for: the moved session's tab takes it when the host is the same; else that tab
/// or an idle tab of the host is replaced; else a new tab opens.
fn open_pushed(a: &PushedArgs) -> Pushed {
    if normalized_device_id(&a.device_id).is_none() {
        return Pushed { action: "drop", key: None };
    }
    let tabs = sorted(&a.tabs);
    let moved = a.moved_from.as_deref().and_then(|from| {
        tabs.iter().find(|t| {
            t.session_id.as_deref() == Some(from) || t.moved_session.as_deref() == Some(from)
        })
    });
    if let Some(moved) = moved
        && moved.device_id == a.device_id
    {
        return Pushed { action: "acceptPushed", key: Some(moved.key.clone()) };
    }
    let idle = tabs.iter().find(|t| t.device_id == a.device_id && !t.pending && !t.streaming);
    match moved.or(idle) {
        Some(t) => Pushed { action: "replace", key: Some(t.key.clone()) },
        None => Pushed { action: "open", key: None },
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SharingArgs {
    on: bool,
    last_host_shared: Option<bool>,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Sharing {
    mark_shared_before: bool,
    /// Seen turning on (or on at the first read): not turned off by the person.
    clear_turned_off: bool,
}

/// Swift then keeps `on` as the last state.
fn host_sharing_changed(a: &SharingArgs) -> Sharing {
    Sharing { mark_shared_before: a.on, clear_turned_off: a.on && a.last_host_shared != Some(true) }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResumeArgs {
    /// The tab's confirmed record is its record.
    confirmed: bool,
    tab_scope: Option<String>,
    pending_scope: Option<String>,
    /// The tab is in `runLinks`.
    run_link: bool,
    /// The record's scope ("view" or "full").
    record_scope: String,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Resume {
    #[serde(skip_serializing_if = "Option::is_none")]
    scope: Option<String>,
    remove_tab_scope: bool,
    remove_pending_scope: bool,
}

/// A confirmed tab resumes with its scope (else the device's waiting one); a run's link with none yet
/// resumes with the link's scope when that is View Only or the tab is confirmed. Swift drops the tab
/// from `runLinks` either way.
fn resume_scope(a: &ResumeArgs) -> Resume {
    let mut out = Resume { scope: None, remove_tab_scope: false, remove_pending_scope: false };
    if a.confirmed {
        out.remove_tab_scope = a.tab_scope.is_some();
        out.remove_pending_scope = a.tab_scope.is_none() && a.pending_scope.is_some();
        out.scope = a.tab_scope.clone().or_else(|| a.pending_scope.clone());
    }
    if a.run_link && out.scope.is_none() && (a.record_scope == "view" || a.confirmed) {
        out.scope = Some(a.record_scope.clone());
    }
    out
}

#[cfg(test)]
#[path = "pages_tests.rs"]
mod tests;
