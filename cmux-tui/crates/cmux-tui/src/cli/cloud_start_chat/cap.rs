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
    /// The command that frees it.
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
            json!(format!("cmux {}", self.command()[..5].join(" ")))
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
