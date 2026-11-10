//! A start that Cloud refused for room names the person's machines and the one-line commands that
//! make room, instead of a bare refusal (Leo, 2026-11-06: "per virtual machine, one workspace ...
//! just arbitrarily many until you hit the cap"). Paid plans have no machine-count cap (Leo,
//! 2026-11-10: "you can have arbitrarily many VMs and we just build based off of that kind of
//! thing"): every machine is metered, and the team's spending cap is the only stop. So no answer here
//! tells a person they hit a machine count. Three refusals still stop a new machine:
//!
//! - the team's spending cap (`cloud.spend_cap.reached`): new starts wait until the cap is raised;
//!   running machines keep working until they pause after the 15-minute warning, nothing lost.
//! - cmux-platform's abuse guard on machines running at once (`cloud.quota.exceeded`, resource
//!   `active`): pausing one frees room.
//! - the guard on machines held, paused ones too (cmux-platform's `resource` `machines`, or the VM
//!   API's "(paused ones count)"): deleting one frees room; chatting on one resumes it.
//!
//! Only the error's code and cmux-platform's own words are read, never a provider's text. The
//! guards' numbers stay in `details.app`, never in the lead.

use serde_json::{Value, json};

use super::at;

/// The error code a refusal answers with: the spending cap is not a machine cap.
pub(super) fn code_of(cap: Cap) -> &'static str {
    match cap {
        Cap::Spend => "cloud.spend_cap",
        Cap::Running | Cap::Held => "cloud.machine_cap",
    }
}

/// The most machines the message names; `details.machines` holds every one.
const NAMED: usize = 8;

/// Which stop refused the create.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Cap {
    /// The team's spending cap: chat on a running machine, or raise the cap.
    Spend,
    /// The guard on machines running at once: pause one.
    Running,
    /// The guard on every machine held, paused ones too: delete one.
    Held,
}

/// The stop a refusal (an app error, or a failed machine's reason) names, if any.
pub(super) fn cap_of(code: &str, message: &str) -> Option<Cap> {
    if code.ends_with("spend_cap.reached") || code.ends_with("spend_cap_reached") {
        return Some(Cap::Spend);
    }
    if message.contains("machines (paused ones count)") || message.contains("paused ones included") {
        return Some(Cap::Held);
    }
    let quota = code.ends_with("quota_exceeded") || code.ends_with("quota.exceeded");
    (quota || message.contains("active machines")).then_some(Cap::Running)
}

/// The refusal in full: what refused, the account's machines (`listed`, `cloud list-machines`'
/// answer) with their status, and the commands for each; `chat` is this command again on one.
/// The app's own words stay out of the lead (a guard's message names a count); callers keep them in
/// `details.app`. At the spending cap only running machines are named: a paused one cannot start.
pub(super) fn at_cap(
    cap: Cap,
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
            ) && !(cap == Cap::Spend && at(row, "status").as_str() == Some("paused"))
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
        Cap::Spend => (
            "your team reached its spending cap, so no new machine starts until the cap is raised; \
             running machines keep working until they pause after a 15-minute warning, and nothing is lost. \
             Chat on a running one",
            "pause",
        ),
        Cap::Running => (
            "too many machines are running at once (a safety limit, not your plan); pause one or chat on one",
            "pause",
        ),
        Cap::Held => (
            "too many machines are kept at once (a safety limit, not your plan); delete one or chat on one \
             (it resumes)",
            "delete",
        ),
    };
    let mut lines = vec![format!("Cloud could not start a new machine: {what}.")];
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
        Cap::Spend => "spend",
        Cap::Running => "running",
        Cap::Held => "held",
    };
    (lines.join("\n"), json!({"cap": cap, "machines": machines}))
}
