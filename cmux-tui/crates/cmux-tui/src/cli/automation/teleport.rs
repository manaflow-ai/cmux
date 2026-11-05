//! `cmux automation teleport NAME --to cloud|home|ssh:HOST[:DIR]` and
//! `cmux automation import --json -` (docs/automations-teleport-teams.md,
//! section 2).
//!
//! One move is three steps, so at most one store fires the automation at any
//! instant: fence the source (it stops firing), the destination accepts the
//! spec with the handoff id as its idempotency key, the source becomes a
//! tombstone. A re-run resumes the pending handoff with the same id. A
//! destination that refuses aborts the move (the fence goes and the source
//! fires again); an answer that never came keeps the fence, since the
//! destination may have accepted, and the message says how to resume or
//! cancel.

use std::io::{Read as _, Write as _};

use cmux_automations::{
    Automation, Body, Destination, ImportHandoff, ImportSpec, Store, Trigger, export_spec,
    new_handoff_id, parse_destination,
};
use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::super::OutputMode;
use super::super::automation_cloud::{self as cloud, Answer};
use super::{Args, Failure, Out, Outcome, messages, now, now_ms, open_store, usage};

/// The ssh program; tests put a fake one first on `PATH`.
const SSH: &str = "ssh";

/// The `cmux` the other machine runs (`CMUX_AUTOMATION_REMOTE_CLI` overrides it).
fn remote_cli() -> String {
    std::env::var("CMUX_AUTOMATION_REMOTE_CLI")
        .ok()
        .filter(|c| !c.trim().is_empty())
        .unwrap_or_else(|| "cmux".into())
}

/// `teleport NAME --to DEST [--abort]`; `cloud_source`: NAME is a Cloud
/// automation (`--target cloud`, or the destination is `home`).
pub(super) fn run(args: &[String], global: &GlobalArgs, out: &Out, cloud_source: bool) -> Outcome {
    let a = Args::parse(args, &["to"], &["abort"])?;
    let name = a.one_word("AUTOMATION")?.to_string();
    let dest = match a.value("to") {
        Some(to) => Some(parse_destination(to.trim()).map_err(Failure::Usage)?),
        None if a.flag("abort") => None,
        None => return usage(messages().teleport_need_to),
    };
    if let Some(Destination::Local { .. }) = dest {
        return usage(messages().teleport_local_dir);
    }
    // `--to home` moves a Cloud automation here; so does `--target cloud`.
    if !cloud_source
        && dest == Some(Destination::Home)
        && let Ok(x) = open_store()?.find(&name)
    {
        return usage(messages().teleport_here.replace("{name}", &x.name));
    }
    if cloud_source || dest == Some(Destination::Home) {
        return from_cloud(&name, dest, a.flag("abort"), global, out);
    }
    let store = open_store()?;
    let x = match store.find(&name) {
        Ok(x) => x,
        Err(cmux_automations::StoreError::NotFound(q)) => {
            return match store.find_moved(&name)? {
                Some(t) => {
                    out_moved(out, &serde_json::to_value(&t).unwrap_or(Value::Null), true);
                    Ok(0)
                }
                None => Err(Failure::Store(cmux_automations::StoreError::NotFound(q))),
            };
        }
        Err(e) => return Err(e.into()),
    };
    if a.flag("abort") {
        let x = store.clear_fence(&x.id)?;
        print_line(
            out,
            &super::automation_json(&store, &x),
            &messages().teleport_aborted.replace("{name}", &x.name),
        );
        return Ok(0);
    }
    match dest {
        Some(Destination::Cloud) => to_cloud(&store, &x, global, out),
        Some(Destination::Ssh { host, dir }) => {
            let to = Destination::Ssh { host: host.clone(), dir: dir.clone() }.to_string();
            let h = store.fence(&x.id, &to, now_ms())?;
            let fenced = store.get(&x.id)?;
            let spec = export_spec(&fenced, &h, &cloud::local_zone_name());
            match ssh_import(&host, dir.as_deref(), &spec) {
                Delivery::Accepted(v) => release(&store, &fenced, &h.id, &to, &v, out),
                Delivery::Refused(error) => {
                    store.clear_fence(&x.id)?;
                    refused(out, &x.name, &to, &error)
                }
                Delivery::Unknown(error) => pending(out, &x.name, &to, &error),
            }
        }
        Some(Destination::Home) => usage(messages().teleport_here.replace("{name}", &x.name)),
        Some(Destination::Local { .. }) | None => usage(messages().teleport_local_dir),
    }
}

/// Every Cloud trigger of a local schedule, or why it has none.
fn cloud_triggers(t: &Trigger) -> Result<Value, Failure> {
    let cron = |expr: String, tz: &str| {
        let tz = if cmux_automations::Zone::parse(tz) == Ok(cmux_automations::Zone::Local) {
            cloud::local_zone_name()
        } else {
            "UTC".to_string()
        };
        json!([{"type": "cron", "expr": expr, "tz": tz}, {"type": "manual"}])
    };
    match t {
        Trigger::Cron { expr, tz } => Ok(cron(expr.clone(), tz)),
        Trigger::Manual => Ok(json!([{"type": "manual"}])),
        Trigger::At { .. } => usage(messages().cloud_local_only.replace("{flag}", "at")),
        Trigger::Every { seconds, anchor } => match every_as_cron(*seconds, *anchor) {
            Some(expr) => Ok(cron(expr, "UTC")),
            None => usage(messages().teleport_every.replace("{value}", &t.describe())),
        },
    }
}

/// `every N` from `anchor` as a UTC cron, when the steps land on the same
/// minutes every hour (N divides an hour) or the same hours every day (N
/// whole hours dividing a day).
pub(super) fn every_as_cron(seconds: u64, anchor: i64) -> Option<String> {
    if seconds == 0 || !seconds.is_multiple_of(60) || anchor % 60 != 0 {
        return None;
    }
    let step = (seconds / 60) as i64;
    let minute = (anchor / 60).rem_euclid(60);
    let list = |start: i64, end: i64, by: i64| {
        (start..end).step_by(by as usize).map(|v| v.to_string()).collect::<Vec<_>>().join(",")
    };
    if step < 60 && 60 % step == 0 {
        return Some(format!("{} * * * *", list((anchor / 60).rem_euclid(step), 60, step)));
    }
    if step % 60 == 0 && 24 % (step / 60) == 0 {
        let hours = step / 60;
        let at = if hours == 1 {
            "*".to_string()
        } else {
            list((anchor / 3_600).rem_euclid(hours), 24, hours)
        };
        return Some(format!("{minute} {at} * * *"));
    }
    None
}

fn to_cloud(store: &Store, x: &Automation, global: &GlobalArgs, out: &Out) -> Outcome {
    let Body::Prompt { prompt, .. } = &x.body else {
        return usage(messages().teleport_command);
    };
    let triggers = cloud_triggers(&x.trigger)?;
    let chief = match cloud::call(global, "chief.list", json!({}), None) {
        Ok(Answer::Value(v)) => cloud::default_chief(&v)
            .ok_or_else(|| Failure::Usage(messages().cloud_no_chief.into()))?,
        Ok(Answer::Refused(error)) => return Ok(out.refusal(&error)),
        Err(error) => return Ok(out.error(&error, 3, false)),
    };
    let h = store.fence(&x.id, "cloud", now_ms())?;
    let x = store.get(&x.id)?;
    let params = json!({
        "name": x.name,
        "description": format!("Moved from {} with cmux automation teleport", x.home),
        "enabled": x.enabled,
        "triggers": triggers,
        "body": {"type": "chief", "chief": chief.0, "conversation": chief.1, "prompt": prompt},
        "catch_up": x.catch_up.name(),
        "handoff": {"id": h.id, "from": x.home, "source_id": x.id, "epoch": h.epoch, "last_slot": x.last_slot},
    });
    match cloud::call(global, "automation.import", params, Some(format!("teleport:{}", h.id))) {
        Ok(Answer::Value(v)) if v.get("id").and_then(Value::as_str).is_some() => {
            release(store, &x, &h.id, "cloud", &v, out)
        }
        Ok(Answer::Value(v)) => pending(
            out,
            &x.name,
            "cloud",
            &json!({"code": "owner.bad_reply", "message": format!("no id in {v}")}),
        ),
        Ok(Answer::Refused(error)) if outcome_unknown(&error) => {
            pending(out, &x.name, "cloud", &error)
        }
        Ok(Answer::Refused(error)) => {
            store.clear_fence(&x.id)?;
            refused(out, &x.name, "cloud", &error)
        }
        Err(error) => pending(out, &x.name, "cloud", &error),
    }
}

/// A refusal that does not say the op never ran (the app's deadline, a bad reply).
fn outcome_unknown(error: &Value) -> bool {
    let code = error.get("code").and_then(Value::as_str).unwrap_or("");
    let state = error
        .get("details")
        .or_else(|| error.get("data"))
        .and_then(|d| d.get("state"))
        .and_then(Value::as_str);
    matches!(code, "timeout" | "owner.bad_reply" | "app.transport" | "in_progress")
        || state == Some("in_progress")
}

/// Step 3 on this Mac: the tombstone naming the destination's id.
fn release(
    store: &Store,
    x: &Automation,
    handoff: &str,
    to: &str,
    accepted: &Value,
    out: &Out,
) -> Outcome {
    let moved_id = accepted.get("id").and_then(Value::as_str).unwrap_or_default();
    let t = store.release(&x.id, handoff, to, moved_id, now_ms())?;
    out_moved(out, &serde_json::to_value(&t).unwrap_or(Value::Null), false);
    Ok(0)
}

fn print_line(out: &Out, v: &Value, line: &str) {
    if out.mode == OutputMode::Json {
        out.value(v);
    } else if out.mode != OutputMode::Quiet {
        println!("{line}");
    }
}

/// Prints a tombstone (`{id, name, moved_to, moved_id, epoch, moved_at}`).
fn out_moved(out: &Out, t: &Value, already: bool) {
    let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("?").to_string();
    let line = if already { messages().teleport_already } else { messages().teleport_moved };
    print_line(
        out,
        t,
        &line
            .replace("{name}", &s("name"))
            .replace("{to}", &s("moved_to"))
            .replace("{id}", &s("moved_id")),
    );
}

fn refused(out: &Out, name: &str, to: &str, error: &Value) -> Outcome {
    if out.mode != OutputMode::Json {
        eprintln!("{}", messages().teleport_refused.replace("{name}", name).replace("{to}", to));
    }
    Ok(out.refusal(error))
}

/// The destination's answer never came: the fence stays.
fn pending(out: &Out, name: &str, to: &str, error: &Value) -> Outcome {
    let why = error.get("message").and_then(Value::as_str).unwrap_or("no answer");
    let message = messages()
        .teleport_pending
        .replace("{name}", name)
        .replace("{to}", to)
        .replace("{why}", why);
    let mut error = error.clone();
    if let Some(map) = error.as_object_mut() {
        map.insert("message".into(), json!(message));
    }
    Ok(out.error(&error, 3, true))
}

/// What the other machine's `import` answered.
enum Delivery {
    Accepted(Value),
    Refused(Value),
    Unknown(Value),
}

/// `ssh HOST cmux automation import --json - [--folder DIR]`, the spec on stdin.
fn ssh_import(host: &str, dir: Option<&str>, spec: &ImportSpec) -> Delivery {
    let mut remote = format!("{} automation import --json -", remote_cli());
    if let Some(dir) = dir {
        remote.push_str(" --folder ");
        remote.push_str(&shell_quote(dir));
    }
    let body = serde_json::to_vec(spec).unwrap_or_default();
    let spawned = cmux_process::Command::new(SSH)
        .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", host, remote.as_str()])
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(e) => {
            return Delivery::Refused(
                json!({"code": "ssh.unavailable", "message": format!("ssh: {e}")}),
            );
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&body);
    }
    let output = match child.wait_with_output() {
        Ok(output) => output,
        Err(e) => {
            return Delivery::Unknown(json!({"code": "ssh.failed", "message": e.to_string()}));
        }
    };
    let stdout: Option<Value> = serde_json::from_slice(&output.stdout).ok();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    match (output.status.code(), stdout) {
        (Some(0), Some(v)) if v.get("id").and_then(Value::as_str).is_some() => {
            Delivery::Accepted(v)
        }
        (Some(0), _) => Delivery::Unknown(
            json!({"code": "ssh.bad_reply", "message": format!("{host} answered no automation")}),
        ),
        (code, _) => {
            // The remote CLI prints its error as JSON on stderr; ssh's own
            // failure (255: no connection, no login) is plain text.
            let remote: Option<Value> =
                stderr.lines().rev().find_map(|l| serde_json::from_str(l).ok());
            Delivery::Refused(remote.filter(|v| v.get("code").is_some()).unwrap_or_else(|| {
                json!({"code": "ssh.failed", "message": messages().ssh_failed
                    .replace("{host}", host)
                    .replace("{code}", &code.map(|c| c.to_string()).unwrap_or_else(|| "signal".into()))
                    .replace("{why}", &stderr)})
            }))
        }
    }
}

/// `'…'` for a POSIX shell.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// A Cloud automation by name or id, from `automation.list`.
enum CloudFound {
    Live(String),
    Moved(Value),
}

fn cloud_lookup(global: &GlobalArgs, word: &str) -> Result<Result<CloudFound, Answer>, Value> {
    let v = match cloud::call(global, "automation.list", json!({"limit": 100}), None)? {
        Answer::Value(v) => v,
        refused => return Ok(Err(refused)),
    };
    let named = |a: &&Value| {
        a.get("id").and_then(Value::as_str) == Some(word)
            || a.get("name")
                .and_then(Value::as_str)
                .is_some_and(|n| n.eq_ignore_ascii_case(word.trim()))
    };
    let list = |k: &str| v.get(k).and_then(Value::as_array).cloned().unwrap_or_default();
    if let Some(id) = list("automations")
        .iter()
        .find(named)
        .and_then(|a| a.get("id")?.as_str().map(str::to_string))
    {
        return Ok(Ok(CloudFound::Live(id)));
    }
    if let Some(t) = list("moved").iter().find(named) {
        return Ok(Ok(CloudFound::Moved(t.clone())));
    }
    if word.starts_with("auto_") && word.len() == 25 {
        return Ok(Ok(CloudFound::Live(word.to_string())));
    }
    Ok(Err(Answer::Refused(json!({"code": "automation.not_found",
        "message": format!("no Cloud automation matches \"{word}\"")}))))
}

fn answer_out(out: &Out, answer: Result<Answer, Value>) -> i32 {
    match answer {
        Ok(Answer::Refused(error)) => out.refusal(&error),
        Ok(Answer::Value(_)) => 0,
        Err(error) => out.error(&error, 3, true),
    }
}

/// Cloud as the source: begin (fence there, answers the spec and
/// `last_slot`), import here or on `ssh:HOST`, complete (tombstone there).
fn from_cloud(
    word: &str,
    dest: Option<Destination>,
    abort: bool,
    global: &GlobalArgs,
    out: &Out,
) -> Outcome {
    let id = match cloud_lookup(global, word) {
        Ok(Ok(CloudFound::Live(id))) => id,
        Ok(Ok(CloudFound::Moved(t))) => {
            out_moved(out, &t, true);
            return Ok(0);
        }
        Ok(Err(answer)) => return Ok(answer_out(out, Ok(answer))),
        Err(error) => return Ok(out.error(&error, 3, false)),
    };
    let current = match cloud::call(global, "automation.get", json!({"automation": id}), None) {
        Ok(Answer::Value(v)) => v.get("automation").cloned().unwrap_or(v),
        other => return Ok(answer_out(out, other)),
    };
    let pending_handoff = current.get("handoff").filter(|h| h.is_object()).cloned();
    if abort {
        let Some(h) = pending_handoff.and_then(|h| h.get("id")?.as_str().map(str::to_string))
        else {
            return usage(messages().teleport_none_pending.replace("{name}", word));
        };
        return match cloud::call(
            global,
            "automation.teleport.abort",
            json!({"automation": id, "handoff": h}),
            Some(format!("teleport-abort:{h}")),
        ) {
            Ok(Answer::Value(v)) => {
                print_line(out, &v, &messages().teleport_aborted.replace("{name}", word));
                Ok(0)
            }
            other => Ok(answer_out(out, other)),
        };
    }
    let dest = match dest {
        Some(Destination::Cloud) => {
            return usage(messages().teleport_in_cloud.replace("{name}", word));
        }
        Some(d @ (Destination::Home | Destination::Ssh { .. })) => d,
        _ => return usage(messages().teleport_need_to),
    };
    let to = dest.to_string();
    let handoff_id = match &pending_handoff {
        Some(h) if h.get("to").and_then(Value::as_str) == Some(to.as_str()) => {
            h.get("id").and_then(Value::as_str).unwrap_or_default().to_string()
        }
        Some(h) => {
            let other = h.get("to").and_then(Value::as_str).unwrap_or("?");
            return usage(
                messages().teleport_other_pending.replace("{name}", word).replace("{to}", other),
            );
        }
        None => new_handoff_id().map_err(|e| Failure::Store(e.into()))?,
    };
    let begun = match cloud::call(
        global,
        "automation.teleport.begin",
        json!({"automation": id, "handoff": {"id": handoff_id, "to": to}}),
        Some(format!("teleport-begin:{handoff_id}")),
    ) {
        Ok(Answer::Value(v)) => v,
        other => return Ok(answer_out(out, other)),
    };
    let spec_of = begun.get("automation").cloned().unwrap_or(Value::Null);
    let name = spec_of.get("name").and_then(Value::as_str).unwrap_or(word).to_string();
    let epoch = begun.get("epoch").and_then(Value::as_u64).unwrap_or(2);
    let spec = ImportSpec {
        name: name.clone(),
        description: spec_of.get("description").and_then(Value::as_str).map(str::to_string),
        enabled: spec_of.get("enabled").and_then(Value::as_bool).unwrap_or(true),
        triggers: spec_of.get("triggers").and_then(Value::as_array).cloned().unwrap_or_default(),
        body: spec_of.get("body").cloned().unwrap_or(Value::Null),
        catch_up: spec_of.get("catch_up").and_then(Value::as_str).map(str::to_string),
        timeout_seconds: None,
        sharing: None,
        handoff: ImportHandoff {
            id: handoff_id.clone(),
            from: "cloud".into(),
            source_id: id.clone(),
            epoch,
            last_slot: begun.get("last_slot").and_then(Value::as_i64),
        },
    };
    let abort_cloud = || {
        let _ = cloud::call(
            global,
            "automation.teleport.abort",
            json!({"automation": id, "handoff": handoff_id}),
            Some(format!("teleport-abort:{handoff_id}")),
        );
    };
    let moved_id = match &dest {
        Destination::Ssh { host, dir } => match ssh_import(host, dir.as_deref(), &spec) {
            Delivery::Accepted(v) => {
                v.get("id").and_then(Value::as_str).unwrap_or_default().to_string()
            }
            Delivery::Refused(error) => {
                abort_cloud();
                return refused(out, &name, &to, &error);
            }
            Delivery::Unknown(error) => return pending(out, &name, &to, &error),
        },
        _ => {
            let local = match spec.to_spec(&cloud::local_zone_name(), None) {
                Ok(local) => local,
                Err(why) => {
                    abort_cloud();
                    return usage(why);
                }
            };
            let store = open_store()?;
            match store.import(local, &spec.handoff, now()) {
                Ok(imported) => imported.automation.id,
                Err(e) => {
                    abort_cloud();
                    return Err(e.into());
                }
            }
        }
    };
    match cloud::call(
        global,
        "automation.teleport.complete",
        json!({"automation": id, "handoff": handoff_id, "moved_id": moved_id}),
        Some(format!("teleport-complete:{handoff_id}")),
    ) {
        Ok(Answer::Value(_)) => {
            let t = json!({"id": id, "name": name, "moved_to": to, "moved_id": moved_id,
                           "epoch": epoch, "moved_at": now_ms()});
            out_moved(out, &t, false);
            Ok(0)
        }
        // The copy is made; the Cloud one stays fenced (it never fires) until a re-run completes it.
        Ok(Answer::Refused(error)) | Err(error) => pending(out, &name, &to, &error),
    }
}

/// `import --json - [--folder DIR]`: an automation another machine sends,
/// idempotent by its handoff id.
pub(super) fn import(args: &[String], out: &Out) -> Outcome {
    let a = Args::parse(args, &["folder"], &[])?;
    if a.one_word("-")? != "-" {
        return usage(messages().import_stdin);
    }
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).map_err(|e| Failure::Store(e.into()))?;
    let spec: ImportSpec = serde_json::from_str(&text)
        .map_err(|e| Failure::Usage(messages().import_bad.replace("{why}", &e.to_string())))?;
    let local = spec
        .to_spec(&cloud::local_zone_name(), a.value("folder"))
        .map_err(|why| Failure::Usage(messages().import_bad.replace("{why}", &why)))?;
    let store = open_store()?;
    let imported = store.import(local, &spec.handoff, now())?;
    let mut v = super::automation_json(&store, &imported.automation);
    if let Value::Object(map) = &mut v {
        map.insert("replayed".into(), json!(imported.replayed));
    }
    let line = if imported.replayed { messages().imported_again } else { messages().imported };
    print_line(
        out,
        &v,
        &line.replace("{name}", &imported.automation.name).replace("{id}", &imported.automation.id),
    );
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn teleport_every_maps_to_cron_only_on_whole_steps() {
        // 2026-10-30 09:07 UTC.
        let anchor = 1_793_350_800 - 3_600 + 7 * 60 + 3_600;
        assert_eq!(every_as_cron(1_800, anchor).as_deref(), Some("7,37 * * * *"));
        assert_eq!(every_as_cron(3_600, anchor).as_deref(), Some("7 * * * *"));
        assert_eq!(every_as_cron(6 * 3_600, anchor).as_deref(), Some("7 3,9,15,21 * * *"));
        assert_eq!(every_as_cron(86_400, anchor).as_deref(), Some("7 9 * * *"));
        assert_eq!(every_as_cron(7 * 60, anchor), None);
        assert_eq!(every_as_cron(5 * 3_600, anchor), None);
        assert_eq!(every_as_cron(1_800, anchor + 30), None);
    }
}
