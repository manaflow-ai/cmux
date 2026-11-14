//! A start that Cloud refused for room names the person's machines and the one-line commands that
//! make room, instead of a bare refusal (Leo, 2026-11-06: "per virtual machine, one workspace ...
//! just arbitrarily many until you hit the cap"). Paid plans have no machine-count cap (Leo,
//! 2026-11-10: "you can have arbitrarily many VMs and we just build based off of that kind of
//! thing"): every machine is metered, and the team's spending cap is the only stop. So no answer here
//! tells a person they hit a machine count. Three refusals still stop a new machine:
//!
//! - the team's spending cap (`cloud.spend_cap.reached`): new starts wait until the cap is raised;
//!   running machines keep working until they pause after the 15-minute warning, nothing lost.
//! - cmux-platform's abuse guard on machines running at once (`cloud.quota.exceeded`,
//!   `details.resource` `active`): pausing one frees room.
//! - the guard on machines held, paused ones too (cmux-platform's `details.resource` `machines`, or
//!   the VM API's "(paused ones count)"): deleting one frees room; chatting on one resumes it.
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

/// The stop a refusal (an app error, or a failed machine's reason) names, if any. `resource` is
/// cmux-platform's `details.resource` when the refusal carries one: `active` and `machines` are the
/// two machine guards, and any other (`saved` snapshots, `environments`) is not a machine stop.
pub(super) fn cap_of(code: &str, message: &str, resource: Option<&str>) -> Option<Cap> {
    // The app hands a failed create on as text only, and a stage's reason has no code: cmux-platform's
    // spending-cap refusal always says "spending cap; an admin can raise it" (SpendCap.ts `capRefusal`).
    if code.ends_with("spend_cap.reached")
        || code.ends_with("spend_cap_reached")
        || message.contains("spending cap; an admin can raise it")
    {
        return Some(Cap::Spend);
    }
    // The provider's VM limit (cmux-platform#1192 `cloud.quota.vm_limit`, the app server's
    // `cmux.cloud.vm_limit`): every machine held counts, paused ones too.
    if code.ends_with("vm_limit") {
        return Some(Cap::Held);
    }
    match resource {
        Some("active") => return Some(Cap::Running),
        Some("machines") => return Some(Cap::Held),
        Some(_) => return None,
        None => {}
    }
    if message.contains("machines (paused ones count)") || message.contains("paused ones included")
    {
        return Some(Cap::Held);
    }
    let quota = code.ends_with("quota_exceeded") || code.ends_with("quota.exceeded");
    (quota || message.contains("active machines")).then_some(Cap::Running)
}

/// The refusal in full: what refused, the account's machines (`listed`, `cloud list-machines`'
/// answer) with their status, and the commands for each; `chat` is this command again on one.
/// The app's own words stay out of the lead (a guard's message names a count); callers keep them in
/// `details.app`. At the spending cap only running machines are named: a paused one cannot start.
pub(super) fn at_cap(cap: Cap, listed: &Value, chat: impl Fn(&str) -> String) -> (String, Value) {
    let machines: Vec<Value> = at(listed, "machines")
        .as_array()
        .into_iter()
        .flatten()
        .filter(|row| match at(row, "status").as_str() {
            Some("failed" | "deleting" | "deleted" | "destroyed") => false,
            Some("paused") => cap != Cap::Spend,
            _ => true,
        })
        .filter_map(|row| {
            let id = at(row, "machine_id").as_str()?;
            let status = at(row, "status").as_str().unwrap_or("unknown");
            let name = at(row, "title").as_str().filter(|t| !t.is_empty()).unwrap_or(id);
            // The VM words the CLI prints (vm_words.rs); every command here takes them.
            let target = format!("vm:{id}");
            Some(json!({
                "machine_id": id, "name": name, "status": status,
                "chat": crate::cli::vm_words::respell(&chat(id)),
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

/// What `--make-room` frees at a cap (cmux-platform Retention.ts `freeUpCandidate`): the machine
/// the platform names by id (`details.free_up.machine`) is deleted; with none named, the paused
/// machine used longest ago that nobody kept is archived and deleted. A machine to delete is never
/// inferred from a name or the refusal's words: only an id the platform gave.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Room {
    pub machine: String,
    pub name: String,
    /// Archive its disk first (`cloud archive-machine`), else delete it (`cloud kill-machine`).
    pub archive: bool,
}

impl Room {
    /// The command that frees it, as this binary runs it as a step (the app's `machine:` words).
    pub(super) fn command(&self) -> Vec<String> {
        let verb = if self.archive { "archive-machine" } else { "kill-machine" };
        let target = format!("machine:{}", self.machine);
        ["cloud", verb, "--target", target.as_str(), "--confirm", "--json"]
            .map(str::to_owned)
            .to_vec()
    }

    pub(super) fn json(&self) -> Value {
        let command = if self.machine.is_empty() {
            Value::Null
        } else {
            // Printed in the CLI's VM words (`cmux vm kill-machine --target vm:ID`, vm_words.rs); the
            // step this binary runs itself keeps the app's `machine:` ([`Room::command`]).
            let words: Vec<String> = self.command().into_iter().take(5).collect();
            json!(super::super::vm_words::respell(&format!("cmux {}", words.join(" "))))
        };
        json!({
            "machine_id": self.machine, "name": self.name,
            "how": if self.archive { "archive" } else { "delete" },
            "command": command,
        })
    }
}

/// The machine `--make-room` would free for the refusal at cap `cap` (the app error's `details`),
/// from the account's machines in `rows`; `None` when there is nothing to free. The plan's running
/// cap is freed by a pause, not a delete: only a `free_up` the platform named counts there.
pub(super) fn room(cap: Cap, details: &Value, rows: &Value) -> Option<Room> {
    let rows: Vec<&Value> = machine_rows(rows);
    let free = at(details, "free_up");
    if let Some(id) = free.get("machine").and_then(Value::as_str).filter(|id| !id.is_empty()) {
        let name = free.get("name").and_then(Value::as_str).filter(|name| !name.is_empty());
        let listed = rows.iter().find(|row| row_id(row) == Some(id)).and_then(|row| row_name(row));
        return Some(Room {
            machine: id.to_owned(),
            name: name.or(listed).unwrap_or(id).to_owned(),
            archive: false,
        });
    }
    if cap != Cap::Held {
        return None;
    }
    // A list without keep (the app's `cloud list-machines` rows): the archive is offered, and
    // `--make-room` picks the machine from the Cloud app's full records when it runs.
    let unknown = rows
        .iter()
        .any(|row| at(row, "status").as_str() == Some("paused") && row.get("keep").is_none());
    oldest_paused(&rows).or_else(|| {
        unknown.then(|| Room {
            machine: String::new(),
            name: "the oldest paused machine nobody kept".to_owned(),
            archive: true,
        })
    })
}

/// The paused machine used longest ago that nobody kept, to archive and delete. A row whose keep
/// is unknown (an older list without the field) counts as kept: never archived on a guess.
pub(super) fn oldest_paused(rows: &[&Value]) -> Option<Room> {
    rows.iter()
        .filter(|row| at(row, "status").as_str() == Some("paused"))
        .filter(|row| row.get("keep").and_then(Value::as_bool) == Some(false))
        .filter_map(|row| Some((used_ms(row)?, *row)))
        .min_by_key(|(used, _)| *used)
        .and_then(|(_, row)| {
            let id = row_id(row)?;
            Some(Room {
                machine: id.to_owned(),
                name: row_name(row).unwrap_or(id).to_owned(),
                archive: true,
            })
        })
}

/// The rows of a `cloud list-machines` answer or of `cloud.machine.list`'s records.
pub(super) fn machine_rows(listed: &Value) -> Vec<&Value> {
    at(listed, "machines").as_array().into_iter().flatten().collect()
}

fn row_id(row: &Value) -> Option<&str> {
    ["machine_id", "id"].iter().find_map(|key| row.get(*key).and_then(Value::as_str))
}

fn row_name(row: &Value) -> Option<&str> {
    ["title", "name"]
        .iter()
        .find_map(|key| row.get(*key).and_then(Value::as_str))
        .filter(|n| !n.is_empty())
}

/// When the machine was last used (ms): its last activity, else its creation, each a number of ms
/// or RFC 3339 text. `None` when neither is readable.
pub(super) fn used_ms(row: &Value) -> Option<i64> {
    let time = |key: &str| match row.get(key)? {
        Value::Number(ms) => ms.as_i64().or_else(|| ms.as_f64().map(|ms| ms as i64)),
        Value::String(text) => cmux_chat_index::time::parse_rfc3339_ms(text),
        _ => None,
    };
    ["last_active_at", "lastActiveAt", "created_at", "createdAt"].iter().find_map(|key| time(key))
}
