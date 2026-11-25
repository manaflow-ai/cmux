//! System alerts on an unattended machine: what they are and which one
//! button may put each off.
//!
//! A Mac nobody sits at collects dialogs the window list hides: they belong
//! to system agents (UserNotificationCenter, CoreServicesUIAgent,
//! SecurityAgent, loginwindow) that are protected targets for every other
//! tool ([`crate::policy`]), and most sit above the layer of app windows.
//! With the opt-in `computerUse.alerts` (default off) two tools reach them:
//!
//! - `list_alerts` reads each one's owner, text and button titles through
//!   accessibility (never its pixels, never a field's value) and names its
//!   class.
//! - `dismiss_alert` presses one button of one listed alert by its
//!   accessibility press action. Only a button that puts the alert off is
//!   ever pressed: [`check`] is the one place that decides, from a table of
//!   known alerts ([`put_off_titles`]) inside a fixed set of titles
//!   ([`PUT_OFF_TITLES`]). A button that grants, allows, opens, reports,
//!   resets or submits is refused whatever the caller says ([`never`]), and
//!   an alert this table does not know is refused by name, so it becomes an
//!   entry here instead of a guess.
//!
//! The classes and rows are the ones the build fleet's unattended-screen
//! tools learned on real Macs (cmuxterm-hq `build-fleet/pr_capture/popup_shot.py`
//! `DIALOG_KINDS` and `KNOWN_ALERTS`, `console_hygiene.py`, leo-workspace
//! `tools/mac_prompt_sweep.py`), so those tools can call this instead.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The setting that turns the two alert tools on.
pub const SETTING: &str = "computerUse.alerts";
/// The code both tools answer while the setting is off.
pub const CODE_OFF: &str = "alerts_off";
/// No alert with that id is on screen now.
pub const CODE_NOT_FOUND: &str = "alert_not_found";
/// The alert's class has no put-off rule.
pub const CODE_UNKNOWN: &str = "alert_unknown";
/// The button is not one this alert may be put off with.
pub const CODE_BUTTON: &str = "alert_button_refused";

/// loginwindow's lock-screen shield windows sit at this layer and above; its
/// dialogs (the out-of-memory Force Quit panel) sit below.
pub const SHIELD_LAYER: i64 = 2000;

/// The only button titles `dismiss_alert` can ever press. Each closes or
/// postpones; none grants, opens or submits.
pub const PUT_OFF_TITLES: &[&str] =
    &["Later", "Not Now", "OK", "Cancel", "Ignore", "Don't Allow", "Deny", "Close"];

/// One system alert as the desktop read it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RawAlert {
    /// The window's id (the `alert_id` an agent passes back).
    pub window_id: String,
    pub pid: u32,
    /// The owning process's name as the window server gives it.
    pub owner: String,
    /// Its bundle id, empty when the system names none.
    pub bundle_id: String,
    pub layer: i64,
    pub title: String,
    /// Its static texts, top to bottom.
    pub texts: Vec<String>,
    /// Its buttons' titles (the window's own close button reads "Close").
    pub buttons: Vec<String>,
    /// It holds a password field (whose value is never read).
    pub secure_field: bool,
    /// Why its text and buttons could not be read, when they could not.
    pub unreadable: Option<String>,
}

/// Whether `owner`'s on-screen window at `layer` is a system alert these
/// tools list. System agents whose windows are dialogs waiting for a person;
/// loginwindow only between the app layer and its lock-screen shields.
pub fn is_alert_window(owner: &str, layer: i64) -> bool {
    match owner {
        "loginwindow" => layer > 0 && layer < SHIELD_LAYER,
        "SecurityAgent"
        | "CoreServicesUIAgent"
        | "UserNotificationCenter"
        | "coreautha"
        | "universalAccessAuthWarn"
        | "tccd"
        | "TCC"
        | "akd"
        | "AuthKitUIService" => layer >= 0,
        _ => false,
    }
}

/// The bundle id of an alert owner the system reports none for.
pub fn known_bundle_id(owner: &str) -> &'static str {
    match owner {
        "SecurityAgent" => "com.apple.SecurityAgent",
        "CoreServicesUIAgent" => "com.apple.coreservices.uiagent",
        "UserNotificationCenter" => "com.apple.UserNotificationCenter",
        "universalAccessAuthWarn" => "com.apple.accessibility.universalAccessAuthWarn",
        "loginwindow" => "com.apple.loginwindow",
        "coreautha" => "com.apple.LocalAuthentication.UIAgent",
        "AuthKitUIService" => "com.apple.AuthKitUIService",
        _ => "",
    }
}

/// Text for matching: straight quotes, no-break spaces as spaces, lower case.
fn norm(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '\u{2018}' | '\u{2019}' | '\u{02BC}' => '\'',
            '\u{201C}' | '\u{201D}' => '"',
            '\u{00A0}' | '\u{202F}' => ' ',
            c => c,
        })
        .collect::<String>()
        .to_lowercase()
}

/// `parts` appear in `text` in this order (a `a.*b.*c` match).
fn seq(text: &str, parts: &[&str]) -> bool {
    let mut rest = text;
    for part in parts {
        match rest.split_once(part) {
            Some((_, after)) => rest = after,
            None => return false,
        }
    }
    true
}

fn any(texts: &[String], test: impl Fn(&str) -> bool) -> bool {
    texts.iter().any(|t| test(t))
}

fn has(texts: &[String], needles: &[&str]) -> bool {
    any(texts, |t| needles.iter().any(|n| t.contains(n)))
}

fn keychain_not_found_text(texts: &[String]) -> bool {
    has(texts, &["keychain not found", "keychain cannot be found"])
}

fn crash_text(texts: &[String]) -> bool {
    has(texts, &["quit unexpectedly", "unexpectedly quit", "closed unexpectedly"])
        || any(texts, |t| seq(t, &["problem", "caused", "to quit"]))
}

/// The alert's title and static texts, normalized, without empty ones.
fn said(alert: &RawAlert) -> Vec<String> {
    std::iter::once(&alert.title)
        .chain(alert.texts.iter())
        .map(|t| norm(t))
        .filter(|t| !t.trim().is_empty())
        .collect()
}

/// The alert's class: the fleet's dialog kinds, first match wins, else
/// `other` (`unreadable` when its text could not be read at all).
pub fn classify(alert: &RawAlert) -> &'static str {
    let owner = alert.owner.as_str();
    let texts = said(alert);
    let t = texts.as_slice();
    if alert.unreadable.is_some() && t.is_empty() && alert.buttons.is_empty() {
        return "unreadable";
    }
    if keychain_not_found(alert) {
        return "keychain-not-found";
    }
    if owner == "UserNotificationCenter"
        && has(t, &["can't connect to icloud because of a problem with"])
    {
        return "icloud-sign-in";
    }
    if has(t, &["enter the password for your apple account", "sign in to icloud"]) {
        return "apple-password";
    }
    if crash_text(t) {
        return "crash-report";
    }
    if owner == "CoreServicesUIAgent" && has(t, &["is damaged and can't be opened"]) {
        return "damaged";
    }
    if owner == "CoreServicesUIAgent"
        && any(t, |x| seq(x, &["can't open the application ", " because it is not responding"]))
    {
        return "not-responding";
    }
    if has(t, &["can't be opened"]) {
        return "cant-be-opened";
    }
    if has(
        t,
        &[
            "access your photo library",
            "access your music, video activity",
            "access your media library",
            "music and video activity",
            "your media library",
            "files managed by",
            "access files in your desktop",
            "access files in your documents",
            "access files in your downloads",
            "access files on a removable volume",
            "access files on a network volume",
        ],
    ) {
        return "protected-folder";
    }
    if has(t, &["bypass the system private window picker"]) {
        return "screen-picker";
    }
    if has(t, &["would like to add vpn configurations"]) {
        return "vpn-configuration";
    }
    if has(t, &["local network"]) {
        return "local-network";
    }
    if has(
        t,
        &["record this computer's screen", "screen recording", "screen & system audio recording"],
    ) {
        return "screen-recording";
    }
    if has(t, &["wants access to control"]) {
        return "automation";
    }
    if has(t, &["accessibility", "would like to control this computer"]) {
        return "accessibility";
    }
    if owner == "CoreServicesUIAgent"
        && has(t, &["downloaded from the internet", "cannot be opened because", "malware"])
    {
        return "gatekeeper";
    }
    if keychain_not_found_text(t) {
        return "keychain-not-found";
    }
    match owner {
        "SecurityAgent" => "keychain",
        "coreautha" => "password",
        "loginwindow" => "out-of-memory",
        // The privacy asks that name no class above (Input Monitoring,
        // Microphone, Camera, "would like to receive keystrokes").
        "universalAccessAuthWarn" | "tccd" | "TCC" => "privacy-access",
        _ if has(t, &["would like to receive keystrokes", "would like to access"]) => {
            "privacy-access"
        }
        _ => "other",
    }
}

/// SecurityAgent's Keychain Not Found panel, which Cancel puts off: it has
/// both Cancel and Reset To Defaults, no password field, and its texts are
/// empty (macOS redacts them from another process) or name a missing
/// keychain. Every other SecurityAgent panel asks for a password.
fn keychain_not_found(alert: &RawAlert) -> bool {
    let button = |title: &str| alert.buttons.iter().any(|b| b == title);
    if alert.owner != "SecurityAgent"
        || alert.secure_field
        || !button("Cancel")
        || !button("Reset To Defaults")
    {
        return false;
    }
    let texts = said(alert);
    texts.is_empty() || keychain_not_found_text(&texts)
}

/// An ask that keeps the fleet reachable and only a person answers
/// (Tailscale's VPN configuration and Local Network asks).
fn person_only(alert: &RawAlert) -> bool {
    has(&said(alert), &["tailscale"])
}

const DENY: &[&str] = &["Don't Allow", "Deny"];

/// The titles that put this alert off, in order of preference; empty when
/// nothing may be pressed on it. `class` is [`classify`]'s answer for it.
pub fn put_off_titles(alert: &RawAlert, class: &str) -> &'static [&'static str] {
    let owner = alert.owner.as_str();
    // A password panel is never pressed, whatever its text or owner says:
    // any alert holding a password field, and every SecurityAgent and
    // coreautha panel but Keychain Not Found (which has no password to give).
    if alert.secure_field {
        return &[];
    }
    if keychain_not_found(alert) {
        return &["Cancel"];
    }
    if matches!(owner, "SecurityAgent" | "coreautha") || person_only(alert) {
        return &[];
    }
    let notifier = owner == "UserNotificationCenter";
    let services = owner == "CoreServicesUIAgent";
    match class {
        "icloud-sign-in" if notifier => &["Later"],
        "apple-password" => &["Not Now", "Cancel", "Later"],
        "crash-report" if notifier => &["Ignore", "OK"],
        "cant-be-opened" | "damaged" if notifier || services => &["OK", "Cancel"],
        "not-responding" if services => &["OK"],
        "gatekeeper" if has(&said(alert), &["downloaded from the internet"]) => &["Cancel"],
        "gatekeeper" => &["Cancel", "OK"],
        "out-of-memory" if owner == "loginwindow" => &["Cancel", "Close"],
        "protected-folder" | "local-network" | "screen-recording" | "automation"
        | "accessibility" | "privacy-access"
            if owner != "loginwindow" =>
        {
            DENY
        }
        _ => &[],
    }
}

/// A title for comparing: straight apostrophe, trimmed.
fn title_key(title: &str) -> String {
    title.trim().replace(['\u{2019}', '\u{2018}', '\u{02BC}'], "'")
}

/// A button that grants, allows, opens, reports, resets, installs, quits or
/// submits: never pressed, whatever a table says (defence in depth under
/// [`PUT_OFF_TITLES`]).
pub fn never(title: &str) -> bool {
    let t = norm(title);
    let t = t.trim().trim_end_matches(['.', '\u{2026}']).trim();
    if t == "don't allow" {
        return false;
    }
    t.starts_with("allow")
        || t.starts_with("always allow")
        || t.starts_with("ok, allow")
        || t.starts_with("open")
        || t.starts_with("reset")
        || t.starts_with("report")
        || t.starts_with("force quit")
        || t.starts_with("limit access")
        || t.starts_with("select photos")
        || t.starts_with("move to")
        || t.starts_with("sign in")
        || t.starts_with("log in")
        || t.starts_with("unlock")
        || t.starts_with("use password")
        || matches!(
            t,
            "reopen"
                | "relaunch"
                | "update"
                | "continue"
                | "install"
                | "restart"
                | "shut down"
                | "delete"
                | "trust"
                | "authorize"
                | "grant"
                | "enable"
                | "turn on"
                | "yes"
                | "done"
                | "resume"
                | "help"
        )
}

/// What `list_alerts` says of one alert.
#[derive(Clone, Debug, PartialEq)]
pub struct Reading {
    pub class: &'static str,
    /// The buttons it has that `dismiss_alert` would press, preferred first
    /// (in the alert's own spelling).
    pub put_off: Vec<String>,
}

pub fn read(alert: &RawAlert) -> Reading {
    let class = classify(alert);
    let put_off = put_off_titles(alert, class)
        .iter()
        .filter_map(|want| alert.buttons.iter().find(|b| title_key(b) == *want).cloned())
        .collect();
    Reading { class, put_off }
}

/// Why a press was refused: the code and the sentence.
#[derive(Clone, Debug, PartialEq)]
pub struct Refused {
    pub code: &'static str,
    pub message: String,
}

fn name_of(alert: &RawAlert, class: &str) -> String {
    let text = said(alert).into_iter().next().unwrap_or_default();
    let text: String = text.chars().take(120).collect();
    format!(
        "alert {} of {} (class {class}, buttons {:?}{})",
        alert.window_id,
        alert.owner,
        alert.buttons,
        if text.is_empty() { String::new() } else { format!(", text {text:?}") }
    )
}

/// The one decision: may `button` be pressed on `alert`? Yes only when the
/// title is one of [`PUT_OFF_TITLES`], is not a [`never`] title, is in the
/// alert's own row ([`put_off_titles`]) and the alert has it. Answers the
/// button's title as the alert spells it.
pub fn check(alert: &RawAlert, button: &str) -> Result<String, Refused> {
    let class = classify(alert);
    let key = title_key(button);
    if never(&key) || !PUT_OFF_TITLES.contains(&key.as_str()) {
        return Err(Refused {
            code: CODE_BUTTON,
            message: format!(
                "{button:?} is never pressed by dismiss_alert: it only presses a button that puts an alert off ({}), never one that allows, grants, opens, reports, resets or submits. Refused on {}.",
                PUT_OFF_TITLES.join(", "),
                name_of(alert, class)
            ),
        });
    }
    let allowed = put_off_titles(alert, class);
    if allowed.is_empty() {
        return Err(Refused {
            code: CODE_UNKNOWN,
            message: format!(
                "No button is pressed on {}: Computer Use has no put-off rule for it. A person answers it; if it should be put off unattended, report it so the rule is added (cmux-computer-use alerts.rs).",
                name_of(alert, class)
            ),
        });
    }
    if !allowed.contains(&key.as_str()) {
        return Err(Refused {
            code: CODE_BUTTON,
            message: format!(
                "{button:?} does not put off {}; dismiss_alert presses only {allowed:?} on it.",
                name_of(alert, class)
            ),
        });
    }
    alert.buttons.iter().find(|b| title_key(b) == key).cloned().ok_or_else(|| Refused {
        code: CODE_BUTTON,
        message: format!("{} has no {button:?} button.", name_of(alert, class)),
    })
}

/// One alert as `list_alerts` answers it.
pub fn to_json(alert: &RawAlert) -> Value {
    let reading = read(alert);
    let mut out = json!({
        "alert_id": alert.window_id,
        "owner": alert.owner,
        "bundle_id": if alert.bundle_id.is_empty() { known_bundle_id(&alert.owner) } else { alert.bundle_id.as_str() },
        "pid": alert.pid,
        "layer": alert.layer,
        "title": alert.title,
        "text": alert.texts,
        "buttons": alert.buttons,
        "class": reading.class,
        "put_off": reading.put_off,
    });
    if let Some(map) = out.as_object_mut() {
        if alert.secure_field {
            map.insert("secure_field".to_string(), json!(true));
        }
        if let Some(why) = &alert.unreadable {
            map.insert("unreadable".to_string(), json!(why));
        }
    }
    out
}

/// The refusal both tools answer while the setting is off.
pub fn off_message(tool: &str) -> String {
    format!(
        "{tool} is off: reading and putting off system alerts needs the {SETTING} setting, which is off by default and only the person (or the machine's owner) turns on. No Computer Use tool changes it."
    )
}

#[cfg(test)]
#[path = "alerts_tests.rs"]
mod tests;
