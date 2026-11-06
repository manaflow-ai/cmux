//! A start that a machine cap refused names the person's machines and the one-line commands that
//! make room, instead of a bare refusal (Leo, 2026-11-06: "per virtual machine, one workspace ...
//! just arbitrarily many until you hit the cap"). Two caps refuse a new machine:
//!
//! - the plan's running machines (`max_active`, Pro 5): cmux-platform pauses the person's least
//!   recently used idle machine first, so only a create with every machine busy is refused
//!   (`cloud.quota.exceeded`, its message "this plan allows N active machines"). Pausing one frees room.
//! - the VM API's machines per team, paused ones too (cmux-platform#919: "this team has its limit
//!   of N machines (paused ones count)"). Deleting one frees room; chatting on one resumes it.
//!
//! Only the error's code and cmux-platform's own words are read, never a provider's text.

use serde_json::{Value, json};

use super::at;

/// The most machines the message names; `details.machines` holds every one.
const NAMED: usize = 8;

/// Which cap refused the create.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Cap {
    /// The plan's running machines: pause one.
    Running,
    /// Every machine the account holds, paused ones too: delete one.
    Held,
}

/// The cap a refusal (an app error, or a failed machine's reason) names, if any.
pub(super) fn cap_of(code: &str, message: &str) -> Option<Cap> {
    if message.contains("machines (paused ones count)") {
        return Some(Cap::Held);
    }
    let quota = code.ends_with("quota_exceeded") || code.ends_with("quota.exceeded");
    (quota || message.contains("active machines")).then_some(Cap::Running)
}

/// The refusal in full: what refused, the account's machines (`listed`, `cloud list-machines`'
/// answer) with their status, and the commands for each; `chat` is this command again on one.
pub(super) fn at_cap(
    cap: Cap,
    refusal: &str,
    listed: &Value,
    chat: impl Fn(&str) -> String,
) -> (String, Value) {
    let machines: Vec<Value> = at(listed, "machines")
        .as_array()
        .into_iter()
        .flatten()
        .filter(|row| {
            !matches!(
                at(row, "status").as_str(),
                Some("failed" | "deleting" | "deleted" | "destroyed")
            )
        })
        .filter_map(|row| {
            let id = at(row, "machine_id").as_str()?;
            let status = at(row, "status").as_str().unwrap_or("unknown");
            let name = at(row, "title").as_str().filter(|t| !t.is_empty()).unwrap_or(id);
            let target = format!("machine:{id}");
            Some(json!({
                "machine_id": id, "name": name, "status": status,
                "chat": chat(id),
                "pause": format!("cmux cloud pause-machine --target {target}"),
                "delete": format!("cmux cloud kill-machine --target {target} --confirm"),
            }))
        })
        .collect();
    let (what, verb) = match cap {
        Cap::Running => {
            ("every running machine of yours is busy; pause one or chat on one", "pause")
        }
        Cap::Held => (
            "your account holds its most machines; delete one or chat on one (it resumes)",
            "delete",
        ),
    };
    let mut lines = vec![format!("{refusal}: {what}.")];
    for machine in machines.iter().take(NAMED) {
        lines.push(format!(
            "  {} ({}): `{}` or `{}`",
            at(machine, "name").as_str().unwrap_or_default(),
            at(machine, "status").as_str().unwrap_or_default(),
            at(machine, "chat").as_str().unwrap_or_default(),
            at(machine, verb).as_str().unwrap_or_default(),
        ));
    }
    if machines.len() > NAMED {
        lines.push(format!(
            "  and {} more: `cmux cloud list-machines`",
            machines.len().saturating_sub(NAMED)
        ));
    }
    let cap = match cap {
        Cap::Running => "running",
        Cap::Held => "held",
    };
    (lines.join("\n"), json!({"cap": cap, "machines": machines}))
}
