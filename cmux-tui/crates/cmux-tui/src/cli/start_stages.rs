//! `stages`: where a Cloud start's time went, for `cmux vm new` and `cmux chat --on vm:new` (Leo, 2026-11-19: "do
//! we have tools for measuring cloud startup at various stages? ... as callable tools that can give instant
//! feedback?"; asked to add it to the CLI: "Yes, add it").
//!
//! The names are the marks scripts/cmux-next/cloud-journey.ts gives a start (`FirstTextTiming`, `create_marks_ms`),
//! so a person's command and the CI journey read the same numbers: each is the milliseconds from the command's start
//! to that mark, and `total` is the whole command. A mark the run never reached is left out. Beside them,
//! `claim_to_bound` is the journey's `claimToBoundSplit` of a create answer that carries the broker's own stage
//! times (`stages_ms`): `claim_answer_ms`, `join_ms`, `guest_bind_ms`, `connect_info_ms`, `bound_ms`.
//!
//! `--timings` prints the same marks as a short table on stderr, so stdout stays the command's answer.

#[cfg(test)]
mod tests;

use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// The flag that prints the table.
pub(super) const FLAG: &str = "--timings";

/// Every mark, in the order a start reaches them, and what it means.
pub(super) const MARKS: &[(&str, &str)] = &[
    ("created", "the create answered"),
    ("running", "the machine is running"),
    ("connect", "linked to the machine: connect_info and the carrier dial"),
    ("machine_config", "its machine config applied"),
    ("secrets", "its secrets delivered"),
    ("session_start", "the chat's tab open; the agent starts"),
    ("session_ready", "the agent runs"),
    ("send", "the prompt goes out"),
    ("sent", "the send answered"),
    ("first_text", "the agent's first output"),
    ("reply", "the turn's end read back"),
    ("total", "the whole command"),
];

/// `words` without `--timings` (before a `--`), and whether it was there.
pub(super) fn take_flag(words: &[String]) -> (Vec<String>, bool) {
    let mut found = false;
    let mut after_dashes = false;
    let kept = words
        .iter()
        .filter(|word| {
            if after_dashes {
                return true;
            }
            if *word == "--" {
                after_dashes = true;
                return true;
            }
            if *word == FLAG {
                found = true;
                return false;
            }
            true
        })
        .cloned()
        .collect();
    (kept, found)
}

/// Marks taken as a run goes: the first time each is reached, from `began`.
#[derive(Debug, Clone)]
pub(super) struct Marks {
    began: Instant,
    at: Map<String, Value>,
}

impl Marks {
    pub(super) fn new(began: Instant) -> Self {
        Self { began, at: Map::new() }
    }

    /// `name` reached at `now`; a mark already taken keeps its first time.
    pub(super) fn mark(&mut self, name: &str, now: Instant) {
        self.set(name, now.saturating_duration_since(self.began));
    }

    /// `name` reached `since` after the start; a mark already taken keeps its first time.
    pub(super) fn set(&mut self, name: &str, since: Duration) {
        self.at.entry(name.to_owned()).or_insert_with(|| json!(ms(since)));
    }

    /// The milliseconds from the start to `name`, when it was reached.
    pub(super) fn get(&self, name: &str) -> Option<u64> {
        self.at.get(name).and_then(Value::as_u64)
    }

    /// The `stages` object, `total` set to `now`.
    pub(super) fn finish(mut self, now: Instant) -> Value {
        self.at.insert("total".into(), json!(ms(now.saturating_duration_since(self.began))));
        Value::Object(self.at)
    }
}

fn ms(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// The journey's `claimToBoundSplit` of a create answer: the broker's ordered `{step|name, ms}` stages (a list, or
/// `{steps: [...]}`) under `stages_ms`, `claim_to_bound` or `claimToBound`, each named one the running sum up to it.
/// None when the answer carries none of them.
pub(super) fn claim_to_bound(answer: &Value) -> Option<Value> {
    let stages =
        ["stages_ms", "claim_to_bound", "claimToBound"].iter().find_map(|key| answer.get(*key))?;
    let entries = stages.as_array().or_else(|| stages.get("steps").and_then(Value::as_array))?;
    let mut out = Map::new();
    let mut total = 0.0;
    for stage in entries {
        let Some(ms) = stage.get("ms").and_then(Value::as_f64) else { continue };
        total += ms;
        let name =
            stage.get("step").or_else(|| stage.get("name")).and_then(Value::as_str).unwrap_or("");
        let key = match name {
            "machine" | "claim" | "claim_answer" => "claim_answer_ms",
            "join" => "join_ms",
            "guest_bind" | "bind" => "guest_bind_ms",
            "connect_info" | "connect" => "connect_info_ms",
            "bound" => "bound_ms",
            _ => continue,
        };
        out.insert(key.to_owned(), json!(total.round() as u64));
    }
    (!out.is_empty()).then_some(Value::Object(out))
}

/// The `--timings` table: each mark reached, its time from the start and from the mark before it, then the
/// claim-to-bound split when there is one.
pub(super) fn table(answer: &Value) -> String {
    let mut out = String::from("stage            at ms     +ms\n");
    let stages = answer.get("stages");
    let mut before = 0;
    for (name, _) in MARKS {
        let Some(at) = stages.and_then(|stages| stages.get(*name)).and_then(Value::as_u64) else {
            continue;
        };
        out.push_str(&format!("{name:<14} {at:>8} {:>7}\n", at.saturating_sub(before)));
        before = before.max(at);
    }
    if let Some(split) = answer.get("claim_to_bound").and_then(Value::as_object) {
        out.push_str("claim to bound (the broker's own times)\n");
        let mut before = 0;
        for key in ["claim_answer_ms", "join_ms", "guest_bind_ms", "connect_info_ms", "bound_ms"] {
            if let Some(at) = split.get(key).and_then(Value::as_u64) {
                let name = key.trim_end_matches("_ms");
                out.push_str(&format!("  {name:<12} {at:>8} {:>7}\n", at.saturating_sub(before)));
                before = before.max(at);
            }
        }
    }
    out
}

/// With `--timings`, the table on stderr; the answer's own printing is unchanged.
pub(super) fn print_table(wanted: bool, answer: &Value) {
    if wanted && answer.get("stages").is_some() {
        eprint!("{}", table(answer));
    }
}

/// `cmux vm new` with no `--wait`, with `--json` or `--timings`: the app's create as one step (`cloud new-machine
/// --json`, run with every one of the caller's globals: `--session`, `--machine`, the sockets and the key), its whole
/// answer as `cmux vm new --json` always printed it (the `action.run` response: `result`, `idempotency_key`) with
/// `stages` (`created` and `total`) and the create's own `claim_to_bound` beside them. A failed create answers its
/// own error with its own exit status (3: no app answered; 1: the app refused). For a person (`--timings` without
/// `--json`) the app's own run, which prints its line and opens the machine's workspace, then the table; None when no
/// app answers it.
pub(super) fn app_create(
    global: &super::GlobalArgs,
    words: &[String],
    timings: bool,
) -> Option<i32> {
    let began = Instant::now();
    if global.output != super::OutputMode::Json {
        let code = super::app::run_cli_action(global, "cloud new-machine", words)?;
        if code == 0 {
            print_table(timings, &with_create_stages(json!({}), began, Instant::now()));
        }
        return Some(code);
    }
    let mut args = vec!["cloud".to_owned(), "new-machine".to_owned()];
    args.extend(words.iter().cloned());
    let ran = super::cloud_start_chat::app_step_as_caller(global, &args);
    match create_answer(&ran, began, Instant::now()) {
        Ok(answer) => {
            print_table(timings, &answer);
            Some(super::wire::print_local_success(&answer, global.output))
        }
        Err((error, code)) => Some(super::wire::print_local_error(&error, global.output, code)),
    }
}

/// The create step's whole `--json` answer with its `stages` (it answered at `now`), or its error and exit status.
pub(super) fn create_answer(
    ran: &super::cloud_start_chat::Ran,
    began: Instant,
    now: Instant,
) -> Result<Value, (Value, i32)> {
    let whole = (ran.code == 0)
        .then(|| super::cloud_start_chat::step_json(&ran.stdout))
        .flatten()
        .filter(Value::is_object);
    match whole {
        Some(whole) => Ok(with_create_stages(whole, began, now)),
        None => {
            let error = match super::cloud_start_chat::step_result(ran) {
                Err(error) => error,
                Ok(_) => json!({"code": "step.failed", "message": "the create printed no answer"}),
            };
            Err((error, if ran.code == 0 { 1 } else { ran.code }))
        }
    }
}

/// A create's answer (its `result`, or the whole response around it) with its `stages` (it answered at `now`)
/// and the create's own split.
pub(super) fn with_create_stages(mut answer: Value, began: Instant, now: Instant) -> Value {
    // The whole `action.run` response carries the create's own times in its `result`.
    let split = claim_to_bound(&answer).or_else(|| answer.get("result").and_then(claim_to_bound));
    if let Some(object) = answer.as_object_mut() {
        let mut marks = Marks::new(began);
        marks.mark("created", now);
        object.insert("stages".into(), marks.finish(now));
        if let Some(split) = split {
            object.insert("claim_to_bound".into(), split);
        }
    }
    answer
}

/// `cmux chat --on vm:new`'s marks from its step trace (`stages_ms`: each step's words, `at` and `ms`, and
/// `cloud start-session`'s own `parts`) and the marks the run took itself (`send`, `sent`, `created` for a machine
/// made with `--environment`). The start-session parts are the app's steps in order (CloudStartSession.swift:
/// `machine`, `connect`, `copy`, `approvals`, `anchor`, `tab`, `start`, `gateway`; a dotted name is a sub-step of the
/// one after it), so each mark is the step's start plus the parts up to it.
pub(super) fn chat(trace: &Value, taken: &Marks, answer: &Value) -> Marks {
    let mut marks = taken.clone();
    let steps = trace.get("steps").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    // The start that answered: a start given up on (a stuck fresh machine) is followed by another.
    let start = steps.iter().rev().find(|step| {
        step.get("step").and_then(Value::as_str) == Some("cloud start-session")
            && step.get("code").and_then(Value::as_i64) == Some(0)
    });
    if let Some(start) = start {
        let mut at = start.get("at").and_then(Value::as_u64).unwrap_or(0);
        let parts = start.get("parts").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
        for part in parts {
            let name = part.get("step").and_then(Value::as_str).unwrap_or_default();
            if name.contains('.') {
                continue;
            }
            at += part.get("ms").and_then(Value::as_u64).unwrap_or(0);
            let mark = match name {
                "machine" => "created",
                "connect" => "connect",
                "tab" => "session_start",
                "start" => "session_ready",
                _ => continue,
            };
            marks.set(mark, Duration::from_millis(at));
        }
        if parts.is_empty()
            && let Some(ms) = start.get("ms").and_then(Value::as_u64)
        {
            marks.set("session_ready", Duration::from_millis(at + ms));
        }
    }
    // The turn's own clock on the machine, from the prompt's arrival: the first output and the end, past `send`.
    if let Some(send) = marks.get("send")
        && let Some(first) = answer.pointer("/turn_ms/first_output").and_then(Value::as_u64)
    {
        marks.set("first_text", Duration::from_millis(send + first));
    }
    marks
}
