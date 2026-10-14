//! The `daemon` service's line filter: a Rust mirror of
//! `Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`.
//! Keep the two lists identical; a command the daemon adds later is refused
//! until it is reviewed and added in both places.

use std::collections::{BTreeSet, HashSet};
use std::sync::LazyLock;

use serde_json::{Map, Value, json};

/// Largest request line the phone may send (the daemon's WebSocket frame cap).
pub const MAXIMUM_LINE_BYTES: usize = 4 * 1024 * 1024;

/// Commands a phone may send.
pub static ALLOWED_COMMANDS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    [
        // Session and discovery (read-only).
        "identify",
        "ping",
        "server-stats",
        "set-client-info",
        "list-clients",
        "list-workspaces",
        "list-workspace-groups",
        "list-tab-groups",
        "list-saved-tab-groups",
        "list-notifications",
        "list-agents",
        "list-terminals",
        "resolve-terminal",
        "process-info",
        "machine-usage",
        "machine-listening-tcp",
        "ids",
        "export-layout",
        "subscribe",
        "terminal-events",
        "wait-for",
        // Terminal streams and input.
        "attach-surface",
        "vt-state",
        "read-screen",
        "read-scrollback",
        "scroll-surface",
        "send",
        "send-key",
        "copy",
        "clear-history",
        "set-terminal-idle-policy",
        "get-cell-pixels",
        "set-cell-pixels",
        // Geometry: per-client leases, released when the phone goes away.
        "set-client-sizing",
        "resize-surface",
        "release-surface-size",
        "resize-attached-view",
        "release-attached-view-size",
        "detach-attached-view",
        // Per-client focus (never moves the Mac's view).
        "client-focus",
        "report-focus",
        // Topology.
        "create-workspace",
        "new-workspace",
        "rename-workspace",
        "close-workspace",
        "move-workspace",
        "set-workspace-metadata",
        "create-workspace-group",
        "update-workspace-group",
        "delete-workspace-group",
        "move-workspace-group",
        "move-workspace-to-group",
        "create-terminal",
        "new-tab",
        "new-screen",
        "new-pane",
        "new-pane-right",
        "split",
        "set-ratio",
        "set-split-ratio",
        "set-viewport-pane-width",
        "undo-layout",
        "pane-neighbor",
        "focus-direction",
        "swap-pane",
        "zoom-pane",
        "close-surface",
        "close-pane",
        "close-screen",
        "close-terminal",
        "rename-pane",
        "rename-surface",
        "rename-screen",
        "focus-pane",
        "select-tab",
        "select-screen",
        "select-workspace",
        "move-tab",
        "move-terminal",
        "set-tab-pinned",
        "move-tab-to-workspace",
        "move-tab-to-split",
        "move-tab-to-column",
        "move-tab-to-new-workspace",
        "create-tab-group",
        "update-tab-group",
        "add-tabs-to-tab-group",
        "remove-tabs-from-tab-group",
        "move-tab-group",
        "move-tab-group-to-split",
        "move-tab-group-to-column",
        "move-tab-group-to-new-workspace",
        "ungroup-tab-group",
        "close-tab-group",
        "save-tab-group",
        "unsave-tab-group",
        "delete-saved-tab-group",
        "reopen-saved-tab-group",
        "ack-tab-notifications",
        "notify",
        // Agent chat tabs: only an acpmux session tab of this Mac's own
        // acpmux, checked below (`agent_tab_verdict`).
        "new-conversation-tab",
        // Browser tabs.
        "new-browser-tab",
        "browser-frame-presented",
        "browser-mouse",
        "browser-mouse-guarded",
        "browser-wheel",
        "browser-wheel-guarded",
        "browser-key",
        "browser-key-press",
        "browser-insert-text",
        "browser-navigate",
        "browser-back",
        "browser-forward",
        "browser-reload",
        "browser-activate",
        // Frontend projections: guarded per subject below.
        "get-frontend-projection",
        "put-frontend-projection",
    ]
    .into_iter()
    .collect()
});

/// Fields a phone may set on commands that start a terminal program. The
/// phone never chooses the program (`argv`, `command`), its directory
/// (`cwd`), its environment (`env`) or a terminal host id.
fn creation_fields(command: &str) -> Option<HashSet<&'static str>> {
    let mutation =
        ["origin", "mutation_id", "expected_generation", "expected_revision", "expected_terminal_revision"];
    let size = ["cols", "rows"];
    let extra: &[&'static str] = match command {
        "new-tab" | "new-pane" => &["pane"],
        "new-pane-right" => &["pane", "width"],
        "split" => &["pane", "dir"],
        "new-screen" => &["workspace"],
        "new-workspace" => &["name"],
        "create-workspace" => return Some(mutation.into_iter().chain(["name", "key"]).collect()),
        "create-terminal" => {
            return Some(mutation.into_iter().chain(size).chain(["workspace", "key", "name"]).collect());
        }
        _ => return None,
    };
    Some(size.into_iter().chain(extra.iter().copied()).collect())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Send the original line.
    Forward,
    /// Send this line instead (no newline): the policy filled in a field the
    /// phone may not choose (the agent tab host).
    Rewrite(Vec<u8>),
    /// Answer the phone with this v12 error line (no newline); never send it on.
    Refuse(String),
}

/// Top-level fields a phone may set on `new-conversation-tab`: a placement,
/// a size and an idempotency key. Never `conversation`/`owner` (another
/// conversation owner) or `page`/`route` (the app's own pages).
const AGENT_TAB_FIELDS: &[&str] =
    &["pane", "workspace", "agent_session", "origin", "mutation_id", "cols", "rows", "transaction"];

/// Fields of `new-conversation-tab`'s `agent_session` a phone may send. The
/// `host` is never the phone's: the policy sets it to this Mac's own agent
/// tab host (the Mac app's `install:<id>`), so the tab runs on this Mac's
/// acpmux and the Mac app shows it as its own chat.
const AGENT_SESSION_FIELDS: &[&str] = &["host", "session", "harness", "host_name"];

/// The per-phone policy.
#[derive(Debug, Clone)]
pub struct DaemonPolicy {
    projection_subject: String,
    /// The `agent_session.host` this Mac's app records on its own agent tabs
    /// (`CNX_AGENT_TAB_HOST`). Unset: a phone cannot create agent tabs.
    agent_tab_host: Option<String>,
}

impl DaemonPolicy {
    pub fn new(device_id: &str) -> Self {
        Self { projection_subject: format!("ios-device:{device_id}"), agent_tab_host: None }
    }

    /// Lets the phone create agent tabs recorded for `host`.
    pub fn with_agent_tab_host(mut self, host: Option<String>) -> Self {
        self.agent_tab_host = host.filter(|host| !host.is_empty());
        self
    }

    /// Judge one newline-stripped request line.
    pub fn evaluate(&self, line: &[u8]) -> Verdict {
        if line.len() > MAXIMUM_LINE_BYTES {
            return Verdict::Refuse(error_line(None, "too_large", "request exceeds 4 MiB"));
        }
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(line) else {
            return Verdict::Refuse(error_line(None, "bad_request", "request is not a JSON object"));
        };
        let id = object.get("id");
        let Some(command) = object.get("cmd").and_then(Value::as_str) else {
            return Verdict::Refuse(error_line(id, "bad_request", "missing cmd"));
        };
        if !ALLOWED_COMMANDS.contains(command) {
            return Verdict::Refuse(error_line(
                id,
                "forbidden",
                &format!("{command} is not available to a phone"),
            ));
        }
        if let Some(allowed) = creation_fields(command) {
            let extra: BTreeSet<&str> = object
                .keys()
                .map(String::as_str)
                .filter(|key| !allowed.contains(key) && *key != "id" && *key != "cmd")
                .collect();
            if !extra.is_empty() {
                let names = extra.into_iter().collect::<Vec<_>>().join(", ");
                return Verdict::Refuse(error_line(
                    id,
                    "forbidden",
                    &format!("{command} does not take {names} from a phone"),
                ));
            }
        }
        if (command == "new-browser-tab" || command == "browser-navigate")
            && let Some(url) = object.get("url")
            && !web_url(url)
        {
            return Verdict::Refuse(error_line(
                id,
                "forbidden",
                "a phone may open only http and https pages",
            ));
        }
        if command == "get-frontend-projection" || command == "put-frontend-projection" {
            return self.projection_verdict(&object, id, command == "put-frontend-projection");
        }
        if command == "new-conversation-tab" {
            let id = id.cloned();
            return self.agent_tab_verdict(object, id);
        }
        Verdict::Forward
    }

    /// `new-conversation-tab` from a phone: an acpmux session tab of this
    /// Mac only. The phone names the agent kind (`harness`), optionally a
    /// session it made through its `acpmux` lane, and where the tab goes;
    /// the host is this Mac's own (set here), so no other machine's chat,
    /// conversation owner or page is ever opened by a phone.
    fn agent_tab_verdict(&self, mut object: Map<String, Value>, id: Option<Value>) -> Verdict {
        let refuse = |code: &str, message: &str| Verdict::Refuse(error_line(id.as_ref(), code, message));
        let Some(host) = &self.agent_tab_host else {
            return refuse("unavailable", "this Mac's cmux does not let a phone start agent chats");
        };
        let extra: BTreeSet<&str> = object
            .keys()
            .map(String::as_str)
            .filter(|key| !AGENT_TAB_FIELDS.contains(key) && *key != "id" && *key != "cmd")
            .collect();
        if !extra.is_empty() {
            let names = extra.into_iter().collect::<Vec<_>>().join(", ");
            return refuse("forbidden", &format!("new-conversation-tab does not take {names} from a phone"));
        }
        let Some(Value::Object(session)) = object.get_mut("agent_session") else {
            return refuse("forbidden", "a phone may only open an agent_session tab");
        };
        if let Some(key) = session.keys().find(|key| !AGENT_SESSION_FIELDS.contains(&key.as_str())) {
            return refuse("forbidden", &format!("agent_session does not take {key} from a phone"));
        }
        if session.get("host").is_some_and(|given| given.as_str() != Some(host.as_str())) {
            return refuse("forbidden", "a phone may only open a chat of this Mac");
        }
        let token = |value: Option<&Value>, max: usize| match value {
            None | Some(Value::Null) => true,
            Some(Value::String(text)) => {
                (1..=max).contains(&text.len())
                    && text
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
            }
            Some(_) => false,
        };
        if !token(session.get("harness"), 64) || !token(session.get("session"), 128) {
            return refuse("bad_request", "agent_session harness and session are short identifiers");
        }
        if session.get("host_name").is_some_and(|name| {
            name.as_str().is_none_or(|name| name.len() > 256 || name.chars().any(char::is_control))
        }) {
            return refuse("bad_request", "agent_session host_name is a short name");
        }
        session.insert("host".into(), Value::String(host.clone()));
        match serde_json::to_vec(&Value::Object(object)) {
            Ok(line) => Verdict::Rewrite(line),
            Err(_) => refuse("bad_request", "request is not a JSON object"),
        }
    }

    fn projection_verdict(&self, object: &Map<String, Value>, id: Option<&Value>, write: bool) -> Verdict {
        let scope = object.get("scope").and_then(Value::as_str);
        let subject = object.get("subject_key").and_then(Value::as_str);
        if scope == Some("personal") && subject == Some(self.projection_subject.as_str()) {
            return Verdict::Forward;
        }
        if !write && scope != Some("personal") {
            return Verdict::Forward;
        }
        Verdict::Refuse(error_line(
            id,
            "forbidden",
            &format!("phones may only use the personal projection {}", self.projection_subject),
        ))
    }
}

/// A web page a phone may open in the Mac's browser: `http(s)://…` or `about:blank`,
/// never `file:`, `javascript:` or an app scheme that would act on the Mac.
fn web_url(url: &Value) -> bool {
    let Some(text) = url.as_str() else { return false };
    let lower = text.trim().to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://") || lower == "about:blank"
}

/// A v12 error response line, keys sorted like the Swift policy.
pub fn error_line(id: Option<&Value>, code: &str, message: &str) -> String {
    json!({"error": message, "error_code": code, "id": id.cloned().unwrap_or(Value::Null), "ok": false})
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> DaemonPolicy {
        DaemonPolicy::new("phone-1")
    }

    #[test]
    fn allows_listed_commands() {
        assert_eq!(policy().evaluate(br#"{"id":1,"cmd":"identify"}"#), Verdict::Forward);
        assert_eq!(
            policy().evaluate(br#"{"id":2,"cmd":"send","surface":3,"text":"ls\n"}"#),
            Verdict::Forward
        );
        assert_eq!(
            policy().evaluate(br#"{"id":3,"cmd":"new-tab","pane":1,"cols":80,"rows":24}"#),
            Verdict::Forward
        );
    }

    /// The exact lines the iOS app's terminal tabs send (CnxLive DaemonTerminalSession
    /// through CnxTransport DaemonClient: flat params, sorted keys, string ids).
    #[test]
    fn allows_the_phone_terminal_session() {
        for line in [
            br#"{"cmd":"identify","id":"m1"}"#.as_slice(),
            br#"{"cmd":"attach-surface","id":"m2","surface":7}"#,
            br#"{"bytes":"bHMK","cmd":"send","id":"m3","surface":7}"#,
            br#"{"cmd":"resize-surface","cols":80,"id":"m4","rows":24,"surface":7}"#,
            br#"{"cmd":"release-surface-size","id":"m5","surface":7}"#,
            br#"{"cmd":"detach-attached-view","id":"m6","surface":7}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        // Starting or replacing the program behind a terminal stays the Mac's.
        for line in [
            br#"{"cmd":"respawn-surface","id":"m7","surface":7,"argv":["sh"]}"#.as_slice(),
            br#"{"cmd":"run","id":"m8","argv":["sh","-c","id"]}"#,
            br#"{"cmd":"create-terminal","id":"m9","workspace":1,"argv":["sh"]}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    #[test]
    fn browser_tabs_open_web_pages_only() {
        assert_eq!(
            policy().evaluate(br#"{"cmd":"new-browser-tab","id":1,"pane":2,"url":"https://example.com"}"#),
            Verdict::Forward
        );
        assert_eq!(
            policy()
                .evaluate(br#"{"cmd":"browser-navigate","id":2,"surface":3,"url":"http://localhost:3000"}"#),
            Verdict::Forward
        );
        for line in [
            br#"{"cmd":"new-browser-tab","id":3,"pane":2,"url":"file:///etc/passwd"}"#.as_slice(),
            br#"{"cmd":"browser-navigate","id":4,"surface":3,"url":"javascript:alert(1)"}"#,
            br#"{"cmd":"browser-navigate","id":5,"surface":3,"url":"cmux://open"}"#,
            br#"{"cmd":"new-browser-tab","id":6,"pane":2,"url":7}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    /// The phone is a remote client, never the app: it cannot prove the install key
    /// (`client-hello`), so the daemon gives its lane origin `agent` and Gate A2
    /// (`user`-only operations) refuses it there too.
    #[test]
    fn the_phone_cannot_claim_the_app_identity() {
        for line in [
            br#"{"cmd":"client-hello","id":"h1","role":"main","install_id":"x"}"#.as_slice(),
            br#"{"cmd":"client-hello","id":"h2","role":"page_relay","page":"settings"}"#,
            br#"{"cmd":"origin.confirmation.issue","id":"h3"}"#,
            br#"{"cmd":"apps.install","id":"h4"}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    #[test]
    fn refuses_unlisted_and_command_bearing_requests() {
        for line in [
            br#"{"id":1,"cmd":"run","argv":["sh"]}"#.as_slice(),
            br#"{"id":1,"cmd":"create-surface-with-receipt"}"#,
            br#"{"id":1,"cmd":"new-tab","argv":["/bin/sh","-c","id"]}"#,
            br#"{"id":1,"cmd":"create-terminal","command":"id"}"#,
            br#"{"id":1,"cmd":"split","cwd":"/"}"#,
            br#"{"id":1,"cmd":"new-workspace","env":{"BASH_ENV":"/tmp/x"}}"#,
            br#"{"id":1,"cmd":"register-browser-provider"}"#,
        ] {
            let Verdict::Refuse(answer) = policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            let answer: Value = serde_json::from_str(&answer).unwrap();
            assert_eq!(answer["ok"], false);
            assert_eq!(answer["error_code"], "forbidden");
            assert_eq!(answer["id"], 1);
        }
    }

    #[test]
    fn bad_json_and_missing_cmd() {
        let Verdict::Refuse(answer) = policy().evaluate(b"not json") else { panic!() };
        assert!(answer.contains("bad_request") && answer.contains("\"id\":null"));
        let Verdict::Refuse(answer) = policy().evaluate(br#"{"id":"a"}"#) else { panic!() };
        assert!(answer.contains("missing cmd") && answer.contains("\"id\":\"a\""));
    }

    #[test]
    fn projections_are_scoped_to_the_phone() {
        let own = br#"{"id":1,"cmd":"put-frontend-projection","scope":"personal","subject_key":"ios-device:phone-1"}"#;
        assert_eq!(policy().evaluate(own), Verdict::Forward);
        let shared_read = br#"{"id":1,"cmd":"get-frontend-projection","scope":"shared"}"#;
        assert_eq!(policy().evaluate(shared_read), Verdict::Forward);
        let shared_write = br#"{"id":1,"cmd":"put-frontend-projection","scope":"shared"}"#;
        assert!(matches!(policy().evaluate(shared_write), Verdict::Refuse(_)));
        let other =
            br#"{"id":1,"cmd":"get-frontend-projection","scope":"personal","subject_key":"ios-device:x"}"#;
        assert!(matches!(policy().evaluate(other), Verdict::Refuse(_)));
    }

    fn agent_policy() -> DaemonPolicy {
        policy().with_agent_tab_host(Some("install:mac-1".into()))
    }

    #[test]
    fn agent_tabs_get_this_macs_host() {
        let line = br#"{"id":1,"cmd":"new-conversation-tab","pane":4,"mutation_id":"k","origin":"ios","agent_session":{"harness":"claude","session":"0199-abc","host_name":"Phone"}}"#;
        let Verdict::Rewrite(rewritten) = agent_policy().evaluate(line) else { panic!("not rewritten") };
        let value: Value = serde_json::from_slice(&rewritten).unwrap();
        assert_eq!(value["agent_session"]["host"], "install:mac-1");
        assert_eq!(value["agent_session"]["harness"], "claude");
        assert_eq!(value["pane"], 4);
        assert_eq!(value["id"], 1);
        // The phone may name this Mac's host itself, never another.
        let own = br#"{"id":1,"cmd":"new-conversation-tab","workspace":2,"agent_session":{"host":"install:mac-1"}}"#;
        assert!(matches!(agent_policy().evaluate(own), Verdict::Rewrite(_)));
    }

    #[test]
    fn agent_tabs_refuse_other_sources_and_hosts() {
        for (line, code) in [
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"host":"registry:x"}}"#.as_slice(), "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"conversation":"c","owner":"local"}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"page":"settings"}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"harness":"claude","command":"sh"}}"#, "forbidden"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"harness":"a b"}}"#, "bad_request"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"session":7}}"#, "bad_request"),
            (br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"host_name":"a\nb"}}"#, "bad_request"),
        ] {
            let Verdict::Refuse(answer) = agent_policy().evaluate(line) else {
                panic!("forwarded {}", String::from_utf8_lossy(line));
            };
            let answer: Value = serde_json::from_str(&answer).unwrap();
            assert_eq!(answer["error_code"], code, "{}", String::from_utf8_lossy(line));
            assert_eq!(answer["id"], 1);
        }
        // Without a configured host (an older Mac app), no agent tabs at all.
        let line = br#"{"id":1,"cmd":"new-conversation-tab","pane":1,"agent_session":{"harness":"claude"}}"#;
        let Verdict::Refuse(answer) = policy().evaluate(line) else { panic!() };
        assert!(answer.contains("unavailable"));
    }

    /// The exact lines the iOS Feed sends for terminal agents (CnxLive
    /// TerminalFeed): the notification ledger read and the per-tab read mark
    /// the Mac's own notifications panel uses. Both were already on the
    /// allowlist; nothing new is opened for the Feed.
    #[test]
    fn allows_the_terminal_feed() {
        for line in [
            br#"{"cmd":"subscribe","id":"m1","tree_events":"deltas"}"#.as_slice(),
            br#"{"cmd":"list-notifications","id":"m2","limit":100}"#,
            br#"{"cmd":"ack-tab-notifications","id":"m3","surface":7}"#,
            br#"{"cmd":"list-agents","id":"m4"}"#,
        ] {
            assert_eq!(policy().evaluate(line), Verdict::Forward, "{}", String::from_utf8_lossy(line));
        }
        // Nothing beyond the ledger: replies into a terminal, the activity
        // stream and the session journal stay refused.
        for line in [
            br#"{"cmd":"notification-reply","id":"m5","notification":1,"text":"y"}"#.as_slice(),
            br#"{"cmd":"subscribe-activity","id":"m6"}"#,
            br#"{"cmd":"session.journal.subscribe","id":"m7"}"#,
        ] {
            assert!(
                matches!(policy().evaluate(line), Verdict::Refuse(_)),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    #[test]
    fn mirrors_the_swift_allowlist() {
        let swift = include_str!(
            "../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift"
        );
        let start = swift.find("allowedCommands: Set<String> = [").expect("allowlist in Swift");
        let end = start + swift[start..].find("]\n").expect("end of allowlist");
        let swift_commands: HashSet<&str> = swift[start..end].split('"').skip(1).step_by(2).collect();
        let rust_commands: HashSet<&str> = ALLOWED_COMMANDS.iter().copied().collect();
        assert_eq!(swift_commands, rust_commands);
    }
}
