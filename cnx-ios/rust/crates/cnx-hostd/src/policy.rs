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
    /// Answer the phone with this v12 error line (no newline); never send it on.
    Refuse(String),
}

/// The per-phone policy.
#[derive(Debug, Clone)]
pub struct DaemonPolicy {
    projection_subject: String,
}

impl DaemonPolicy {
    pub fn new(device_id: &str) -> Self {
        Self { projection_subject: format!("ios-device:{device_id}") }
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
        if command == "get-frontend-projection" || command == "put-frontend-projection" {
            return self.projection_verdict(&object, id, command == "put-frontend-projection");
        }
        Verdict::Forward
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
