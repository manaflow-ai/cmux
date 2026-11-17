//! The person's side of consent on a desktop host: the viewers waiting (`requests`), and the
//! `approve` and `deny` that answer them. Only a request this host recorded can be answered.

use super::consent::{self, LocalConsent, Pending};
use super::{COMMAND, TAG};
use crate::Res;
use cmux_hub_host::hub::{now_ms, Hub};
use cmux_hub_host::printable;
use std::path::Path;

/// One `requests` line.
pub fn request_line(r: &consent::Request) -> String {
    let what = if r.scope == "full" { "control" } else { "view" };
    let fp = match r.viewer_key_fingerprint.as_deref().map(printable) {
        // 16 characters, not bytes: a byte cut panics inside a multi-byte character.
        Some(f) if !f.is_empty() => f.chars().take(16).collect(),
        _ => "-".to_owned(),
    };
    format!(
        "{}  {} (key {fp}) asks to {what} this desktop",
        printable(&r.id),
        printable(&r.viewer_name)
    )
}

/// The log line for a viewer waiting for the person.
pub fn ask_line(r: &consent::Request) -> String {
    let what = if r.scope == "full" { "control" } else { "view" };
    let id = printable(&r.id);
    format!(
        "{TAG}: {} asks to {what} this desktop. Allow: {COMMAND} approve {id} [--always]; refuse: {COMMAND} deny {id}",
        printable(&r.viewer_name)
    )
}

/// `requests`: the viewers waiting, one line each.
pub fn list(runtime: &Path) -> Res<()> {
    let list = Pending::new(runtime).list(now_ms())?;
    if list.is_empty() {
        println!("No viewer is waiting.");
    }
    for r in list {
        println!("{}", request_line(&r));
    }
    Ok(())
}

/// `approve ID [--always] [--scope view|full]`. `no_input`: why this host applies no input
/// (None when it does), said when a control request is lowered to view for that.
pub fn approve(
    dir: &Path,
    runtime: &Path,
    hub: &Hub,
    id: &str,
    scope: Option<&str>,
    always: bool,
    no_input: Option<&str>,
) -> Res<()> {
    let pending = Pending::new(runtime);
    let now = now_ms();
    // Only a request this host recorded: an id from anywhere else is refused.
    let request = pending
        .list(now)?
        .into_iter()
        .find(|r| r.id == id)
        .ok_or_else(|| format!("no waiting request {id} (see `{COMMAND} requests`)"))?;
    let decided =
        consent::decision_scope(&request, scope, LocalConsent::load(dir)?, no_input.is_none())?;
    let decision = if always { "always" } else { "once" };
    hub.decide(id, decision, Some(&decided))?;
    pending.remove(id, now)?;
    let lowered = request.scope == "full" && decided == "view" && scope.is_none();
    println!(
        "Approved {} to {} this desktop{}{}.",
        printable(&request.viewer_name),
        if decided == "full" { "control" } else { "view" },
        if always { " from now on" } else { " once" },
        if lowered { no_input.unwrap_or_default() } else { "" }
    );
    Ok(())
}

/// `deny ID`.
pub fn deny(runtime: &Path, hub: &Hub, id: &str) -> Res<()> {
    let pending = Pending::new(runtime);
    let now = now_ms();
    pending
        .list(now)?
        .into_iter()
        .find(|r| r.id == id)
        .ok_or_else(|| format!("no waiting request {id}"))?;
    hub.decide(id, "deny", None)?;
    pending.remove(id, now)?;
    println!("Denied.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(name: &str, fingerprint: Option<&str>) -> consent::Request {
        consent::Request {
            id: "s1".into(),
            viewer_id: "v1".into(),
            viewer_name: name.into(),
            viewer_key_fingerprint: fingerprint.map(str::to_owned),
            scope: "view".into(),
            received_ms: 0,
        }
    }

    #[test]
    fn hub_text_is_printed_without_control_characters() {
        assert_eq!(printable("Ann's Mac"), "Ann's Mac");
        assert_eq!(printable("\u{1b}[2J\u{1b}[31mEvil\u{1b}[0m"), "Evil");
        assert_eq!(printable("a\u{1b}]0;title\u{7}b"), "ab");
        assert_eq!(printable("x\ny\rz\t\u{0}\u{7f}\u{9b}1m"), "xyz1m");
        assert_eq!(printable("\u{202e}cod.exe\u{202c}\u{2066}\u{200f}"), "cod.exe");
        let hostile = "\u{1b}[2J\u{202e}Mallory\nlinux-host: approved";
        for line in [request_line(&request(hostile, None)), ask_line(&request(hostile, None))] {
            assert!(
                !line.chars().any(|c| c.is_control() || cmux_hub_host::text::is_bidi_control(c)),
                "{line:?}"
            );
            assert!(line.contains("Mallorylinux-host: approved"), "{line:?}");
        }
    }

    #[test]
    fn fingerprints_are_cut_on_a_character_boundary() {
        // 15 ASCII bytes then a 3-byte character across the 16-byte mark.
        let fp = "0123456789abcde\u{20ac}\u{20ac}tail";
        let line = request_line(&request("Ann", Some(fp)));
        assert!(line.contains("(key 0123456789abcde\u{20ac})"), "{line}");
        let line = request_line(&request("Ann", Some("\u{1b}[31m\u{e9}")));
        assert!(line.contains("(key \u{e9})"), "{line}");
        assert!(request_line(&request("Ann", None)).contains("(key -)"));
    }

    #[test]
    fn the_ask_line_names_this_hosts_commands() {
        let line = ask_line(&request("Ann", None));
        assert!(line.starts_with(&format!("{TAG}: Ann asks to view")), "{line}");
        assert!(line.contains(&format!("{COMMAND} approve s1")), "{line}");
        assert!(line.contains(&format!("{COMMAND} deny s1")), "{line}");
    }
}
