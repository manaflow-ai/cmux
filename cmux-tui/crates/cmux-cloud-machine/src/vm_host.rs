//! A Cloud machine's acpmux `vmHost` (acpmux `hub/vm_host.rs`), Settings > Machines' "Dedicated
//! agent machine" switch: whether it takes its owner's VM boundary when the owner's own app link
//! asks for it. The machine never decides that: a remote chain from this app's link runs without
//! the sandbox only when the Cloud API told this app it owns the machine (`vmKind: "owner"`).
//!
//! Read and set over the Cloud API's exec, one short command each: the machine's own
//! `cmux-tui acp --json host vm-host [on|off]`, run as the machine's work user (or root on an
//! image from before the work user), which answers `{vmHost, cmuxVm, configured}`. The app's
//! `CloudVmHostStore` runs the commands and keeps the answers.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The exec's budget: well under the exec API's 25 s.
pub const TIMEOUT_MS: u64 = 15_000;
/// A failed read is tried again once it is this old (the next time its row is drawn).
pub const RETRY_AFTER_MS: u64 = 60_000;

/// What the machine said.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    /// On now.
    pub on: bool,
    /// cmux created this machine for its owner, so on is its default and may be turned on.
    #[serde(rename = "cmuxVM")]
    pub cmux_vm: bool,
}

/// The command that reads the setting (`on` None) or sets it.
pub fn command(on: Option<bool>) -> String {
    let state = match on {
        None => "",
        Some(true) => " on",
        Some(false) => " off",
    };
    [
        "set -eu",
        r#"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#,
        r#"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#,
        r#"u=cmux; id -u "$u" >/dev/null 2>&1 || u=root"#,
        r#"h=$(getent passwd "$u" | cut -d: -f6)"#,
        r#"b="$h/.cmux/bin/cmux-tui""#,
        r#"[ -x "$b" ] || { echo "cmux: this machine has no cmux-tui" >&2; exit 82; }"#,
        &format!(r#"as_u env HOME="$h" "$b" acp --json host vm-host{state}"#),
    ]
    .join("; ")
}

/// The JSON object that starts at the text's first `{`, if the rest is one.
fn object_in(text: &str) -> Option<Value> {
    let (_, after) = text.split_once('{')?;
    serde_json::from_str::<Value>(&format!("{{{after}")).ok().filter(Value::is_object)
}

/// The state in a successful exec's output (acpmux prints one JSON object, pretty), or None.
pub fn parse(exit_code: i64, stdout: &str) -> Option<State> {
    if exit_code != 0 {
        return None;
    }
    let object = object_in(stdout)?;
    let on = object.get("vmHost")?.as_bool()?;
    Some(State { on, cmux_vm: object.get("cmuxVm").and_then(Value::as_bool).unwrap_or(false) })
}

/// Why a failed exec failed, in the machine's words, bounded to 300 characters: acpmux's
/// `--json` error envelope's message, else the first line (an older cmux-tui's usage error, the
/// shell's), else the exit code.
pub fn failure(exit_code: i64, stdout: &str, stderr: &str) -> String {
    let text = if stderr.is_empty() { stdout } else { stderr };
    let bounded = |line: &str| line.chars().take(300).collect::<String>();
    if let Some(message) = object_in(text)
        .and_then(|object| object.get("error")?.get("message")?.as_str().map(str::to_owned))
    {
        return bounded(&message);
    }
    let newline = |c: char| {
        matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    };
    match text.split(newline).find(|line| !line.is_empty()) {
        Some(line) => bounded(line),
        None => format!("exit {exit_code}"),
    }
}

/// Whether a row's entry should be read again: none known yet, or a failure `age_ms` old that
/// is at least a minute old (`failed_age_ms` None: the entry is known).
pub fn stale(known: bool, failed_age_ms: Option<u64>) -> bool {
    match failed_age_ms {
        Some(age) => age >= RETRY_AFTER_MS,
        None => !known,
    }
}

#[cfg(test)]
mod tests;
