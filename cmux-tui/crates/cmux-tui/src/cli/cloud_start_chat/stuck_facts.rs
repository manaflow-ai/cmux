//! What a stuck machine said about itself, read just before fresh.rs deletes it.
//!
//! Production, 2026-11-19 19:43Z (cmuxterm-hq `cloud-chat-replies-production`, run 44591153939): both machines of
//! one start took about 27 s to provision, never registered with the relay (every carrier dial ended
//! `parked_timeout`), and were deleted at the bound (cmux#46029). The probe's own reads came after the delete and
//! found nothing ("No Cloud machine has the id ...", "diagnostics: no row for this machine"), so why they stuck was
//! never known. These reads run while the machine still exists, and their answers go in the start's own answer
//! (each `fresh_retry` row's `facts`).
//!
//! Each read is bounded by its own few seconds (and by the run's deadline), and a read that fails, refuses or runs
//! past its bound is named under `unread`: the delete and the retry run after it either way.
//!
//! The provider's own boot or serial-console log has no read: neither the app nor the platform's machine API
//! (cmux-platform `workers/cmux-vm`) exposes one, so it is named under `unavailable` on every row.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::internal::bounded::{self, PAST_DEADLINE};
use super::{Deadline, Ran, Runner, at, step_result, words};

/// The longest the app's own reads (`machine-status`, `diagnostics`) may take.
pub(super) const READ_BOUND: Duration = Duration::from_secs(5);

/// The longest the guest's journal read (`cloud exec`, over the machine API: it needs no link) may take. The
/// script on the guest is ended a few seconds sooner ([`bounded::remote_script`]).
pub(super) const GUEST_READ_BOUND: Duration = Duration::from_secs(8);

/// What the guest says about why its session host did or did not come up: the image it booted, whether
/// `cmux-host` runs, its uptime and the host's last journal lines (through `sudo -n`, as the image lets the work
/// user; a refusal is kept as the log's text). The same read cmuxterm-hq's probe makes (`GUEST_FACTS`).
const GUEST_SCRIPT: &str = "for f in image-stamp bake-instance-id vm-kind; do printf '%s=' \"$f\"; head -c 200 \
     \"/etc/cmux/$f\" 2>/dev/null | tr -d '\\n'; echo; done; printf 'cmux_host=%s\\n' \"$(systemctl is-active \
     cmux-host.service 2>/dev/null)\"; printf 'uptime_s=%s\\n' \"$(cut -d. -f1 /proc/uptime)\"; echo '--journal--'; \
     j=$(sudo -n journalctl -u cmux-host.service -n 40 --no-pager -o short-iso 2>&1) || j=\"journal unreadable: $j\"; \
     printf '%s\\n' \"$j\" | tail -c 4000";

/// The guest's `key=value` facts kept from [`GUEST_SCRIPT`].
const GUEST_KEYS: &[&str] =
    &["image-stamp", "bake-instance-id", "vm-kind", "cmux_host", "uptime_s"];

/// How much of the guest's journal tail is kept.
const LOG_CHARS: usize = 2000;

/// What no read here can get, and which service would have to expose it.
const UNAVAILABLE: &str = "the provider's boot or serial-console log: no read exists; the platform's machine API \
     (cmux-platform workers/cmux-vm) would need to expose it";

/// The facts of the machine `id` (listed as `listed`, made by the attempt whose stage trace is `stages`), read
/// before its delete. Never fails: what a read could not get is named under `unread`.
pub(super) fn read(
    runner: &mut dyn Runner,
    id: &str,
    listed: &Value,
    stages: &Value,
    deadline: Deadline,
) -> Value {
    let mut facts = Map::new();
    let mut unread = Vec::new();
    facts.insert("machine_id".into(), json!(id));
    // Its create: when the platform says it was made, and the attempt's own steps (the app's split of the start
    // under each step's `parts` and `detail`: the machine, its connect, the agent).
    facts.insert("listed".into(), scalars(listed));
    if !stages.is_null() {
        facts.insert("create_ms".into(), stages.clone());
    }
    let target = format!("machine:{id}");

    match bounded_step(
        runner,
        &["cloud", "machine-status", "--target", &target, "--json"],
        deadline,
        READ_BOUND,
    ) {
        Ok(status) => {
            facts.insert("status".into(), status);
        }
        Err(why) => unread.push(format!("machine-status: {why}")),
    }

    match bounded_step(runner, &["cloud", "diagnostics", "--json"], deadline, READ_BOUND) {
        Ok(report) => match diagnostics_row(&report, id) {
            Some(row) => {
                facts.insert("diagnostics".into(), row);
            }
            None => unread.push("diagnostics: no row for this machine".to_owned()),
        },
        Err(why) => unread.push(format!("diagnostics: {why}")),
    }

    match guest(runner, &target, deadline) {
        Ok(guest) => {
            facts.insert("guest".into(), guest);
        }
        Err(why) => unread.push(format!("guest log: {why}")),
    }

    if !unread.is_empty() {
        facts.insert("unread".into(), json!(unread));
    }
    facts.insert("unavailable".into(), json!([UNAVAILABLE]));
    Value::Object(facts)
}

/// One `cmux` step ended at `own` from now (or the run's deadline when sooner): its result, or why there is none.
fn bounded_step(
    runner: &mut dyn Runner,
    args: &[&str],
    deadline: Deadline,
    own: Duration,
) -> Result<Value, String> {
    let bound = deadline.bound(runner, own);
    if bound.is_zero() {
        return Err("the run's --timeout left no time".to_owned());
    }
    let until = runner.now() + bound;
    let ran = runner.cmux_by(&words(args), until);
    answer(&ran, bound)
}

fn answer(ran: &Ran, bound: Duration) -> Result<Value, String> {
    if ran.code == PAST_DEADLINE {
        return Err(format!("no answer within {} s", bound.as_secs()));
    }
    step_result(ran).map_err(|error| {
        let code = at(&error, "code").as_str().unwrap_or("failed");
        let message = at(&error, "message").as_str().unwrap_or_default();
        clip(&format!("exit {}: {code}: {message}", ran.code), 300)
    })
}

/// The guest's facts and its host journal's tail, over `cloud exec`.
fn guest(runner: &mut dyn Runner, target: &str, deadline: Deadline) -> Result<Value, String> {
    let bound = deadline.bound(runner, GUEST_READ_BOUND);
    let Some(script) = bounded::remote_script(GUEST_SCRIPT, bound) else {
        return Err("the run's --timeout left no time".to_owned());
    };
    let until = runner.now() + bound;
    let args = ["cloud", "exec", "--target", target, "--command", script.as_str(), "--json"];
    let ran = answer(&runner.cmux_by(&words(&args), until), bound)?;
    let stdout = at(&ran, "stdout").as_str().unwrap_or_default();
    let mut guest = Map::new();
    if let Some(code) = at(&ran, "exit_code").as_i64()
        && code != 0
    {
        guest.insert("exit_code".into(), json!(code));
    }
    let (head, journal) = stdout.split_once("--journal--").unwrap_or((stdout, ""));
    for line in head.lines() {
        if let Some((key, value)) = line.split_once('=')
            && GUEST_KEYS.contains(&key)
            && !value.trim().is_empty()
        {
            guest.insert(key.replace('-', "_"), json!(clip(value.trim(), 200)));
        }
    }
    let journal = journal.trim();
    if !journal.is_empty() {
        guest.insert("host_log".into(), json!(tail(journal, LOG_CHARS)));
    }
    Ok(Value::Object(guest))
}

/// This machine's row of `cloud diagnostics` (its `details`, an object or its JSON text: per machine the link
/// stage, its detail, the connection state and the daemon's handshake), its scalar values only.
fn diagnostics_row(report: &Value, id: &str) -> Option<Value> {
    let details = at(report, "details");
    let parsed;
    let details = match details.as_str() {
        Some(text) => {
            parsed = serde_json::from_str::<Value>(text).ok()?;
            &parsed
        }
        None if details.is_object() => details,
        None => report,
    };
    at(details, "machines").as_array()?.iter().find_map(|row| {
        let ours =
            [at(row, "id"), at(row, "machine_id")].iter().any(|key| key.as_str() == Some(id));
        ours.then(|| scalars(row))
    })
}

/// `row`'s scalar values (strings clipped), sorted by key: never an account's nested facts.
fn scalars(row: &Value) -> Value {
    let Some(row) = row.as_object() else { return Value::Null };
    let mut kept = Map::new();
    for (key, value) in row {
        match value {
            Value::String(text) => {
                kept.insert(key.clone(), json!(clip(text, 300)));
            }
            Value::Null | Value::Bool(_) | Value::Number(_) => {
                kept.insert(key.clone(), value.clone());
            }
            _ => {}
        }
    }
    Value::Object(kept)
}

fn clip(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}

fn tail(text: &str, chars: usize) -> String {
    let count = text.chars().count();
    text.chars().skip(count.saturating_sub(chars)).collect()
}
