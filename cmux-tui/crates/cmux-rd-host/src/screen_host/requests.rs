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
#[path = "requests_tests.rs"]
mod tests;
