//! Snapshots held back from the log (`store/deferred.rs`).

use super::*;
use serde_json::json;

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}})
}

fn snapshot(id: &str, text: &str) -> Value {
    update(json!({
        "sessionUpdate": "tool_call_update", "toolCallId": id,
        "_meta": {"terminal_output_delta": {"data": "x"}},
        "content": [{"type": "content", "content": {"type": "text", "text": text}}],
    }))
}

fn start(id: &str) -> Value {
    update(
        json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cargo test", "kind": "execute", "status": "in_progress"}),
    )
}

/// The log as `Hub::append_at_locked` writes it: for each record, the held ones it makes due, then
/// it (or its stub).
fn log(records: &[(&str, &str, Value, u64)]) -> Vec<(String, Value)> {
    let mut deferral = Deferral::default();
    let mut out = Vec::new();
    for (dir, kind, msg, at) in records {
        let keep = deferral.keep(dir, kind, msg, *at, true);
        out.extend(keep.before.into_iter().map(|(k, m)| (k.to_owned(), m)));
        out.push(((*kind).to_owned(), keep.stored.unwrap_or_else(|| msg.clone())));
    }
    out
}

fn content(msg: &Value) -> Option<&Value> {
    msg.pointer("/params/update/content")
}

/// Each call's content as a reader that folds the log in order ends it: content replaces.
fn contents(log: &[(String, Value)]) -> BTreeMap<String, Value> {
    let mut out = BTreeMap::new();
    for (_, msg) in log {
        if let (Some(id), Some(c)) =
            (msg.pointer("/params/update/toolCallId").and_then(Value::as_str), content(msg))
        {
            out.insert(id.to_owned(), c.clone());
        }
    }
    out
}

#[test]
fn a_running_commands_snapshots_are_stubbed_and_its_newest_stored_before_the_answer() {
    let records = vec![
        ("in", "tool_call", start("c"), 0),
        ("in", "tool_call_update", snapshot("c", "aaaa"), 10),
        ("in", "tool_call_update", snapshot("c", "aaaab"), 20),
        ("in", "tool_call_update", snapshot("c", "aaaabc"), 30),
        (
            "in",
            "tool_call_update",
            update(
                json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed", "rawOutput": {"exit_code": 0}}),
            ),
            40,
        ),
        ("mux", "turn_result", json!({"status": "completed"}), 50),
    ];
    let log = log(&records);
    // The first snapshot is held (it is within MAX_AGE_MS of the call's start), then replaced.
    let stubs = log
        .iter()
        .filter(|(_, m)| m.pointer("/params/update/_meta/acpmux/supersededContent").is_some())
        .count();
    assert_eq!(stubs, 3, "{log:#?}");
    // The newest one is stored once, just before the end that carries no content.
    let late: Vec<_> = log.iter().filter(|(_, m)| content(m).is_some()).collect();
    assert_eq!(late.len(), 1, "{log:#?}");
    assert_eq!(log[log.len() - 3].1, {
        let mut m = snapshot("c", "aaaabc");
        m["params"]["update"].as_object_mut().unwrap().remove("_meta");
        m
    });
    assert_eq!(
        contents(&log),
        contents(
            &records.iter().map(|(_, k, m, _)| (k.to_string(), m.clone())).collect::<Vec<_>>()
        )
    );
    // The stub keeps every increment.
    let deltas = log
        .iter()
        .filter(|(_, m)| m.pointer("/params/update/_meta/terminal_output_delta").is_some())
        .count();
    assert_eq!(deltas, 3);
}

#[test]
fn a_snapshot_twice_the_last_stored_or_old_is_stored_whole() {
    let mut deferral = Deferral::default();
    let _ = deferral.keep("in", "tool_call", &start("c"), 0, true);
    let at = MAX_AGE_MS;
    let first = deferral.keep("in", "tool_call_update", &snapshot("c", "aaaa"), at, true);
    assert!(first.stored.is_none(), "old: stored whole");
    let thin = deferral.keep("in", "tool_call_update", &snapshot("c", "aaaabbb"), at + 1, true);
    assert!(thin.stored.is_some(), "under twice: held");
    let grown = deferral.keep("in", "tool_call_update", &snapshot("c", "aaaabbbb"), at + 2, true);
    assert!(grown.stored.is_none() && grown.before.is_empty(), "twice: stored, the held one moot");
}

#[test]
fn an_update_that_carries_more_than_output_is_never_held() {
    let mut deferral = Deferral::default();
    let _ = deferral.keep("in", "tool_call", &start("c"), 0, true);
    let mut titled = snapshot("c", "a");
    titled["params"]["update"]["title"] = json!("retitled");
    assert!(deferral.keep("in", "tool_call_update", &titled, 1, true).stored.is_none());
    let mut diff = snapshot("c", "a");
    diff["params"]["update"]["content"] =
        json!([{"type": "diff", "path": "a", "oldText": "", "newText": "b"}]);
    assert!(deferral.keep("in", "tool_call_update", &diff, 2, true).stored.is_none());
    let mut subagent = snapshot("c", "a");
    subagent["params"]["_meta"] = json!({"codex": {"subagent": "x"}});
    assert!(deferral.keep("in", "tool_call_update", &subagent, 3, true).stored.is_none());
    let ending = {
        let mut m = snapshot("c", "a");
        m["params"]["update"]["status"] = json!("completed");
        m
    };
    assert!(deferral.keep("in", "tool_call_update", &ending, 4, true).stored.is_none());
    // A copy (a fork's) is never held.
    let _ = deferral.keep("in", "tool_call", &start("d"), 0, true);
    assert!(
        deferral.keep("in", "tool_call_update", &snapshot("d", "a"), 1, false).stored.is_none()
    );
}

#[test]
fn a_status_after_the_held_snapshot_is_not_undone_by_it() {
    let mut held = snapshot("c", "a");
    held["params"]["update"]["status"] = json!("pending");
    let records = vec![
        ("in", "tool_call", start("c"), 0),
        ("in", "tool_call_update", held, 1),
        (
            "in",
            "tool_call_update",
            update(
                json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "in_progress"}),
            ),
            2,
        ),
        ("mux", "status", json!({"status": "idle"}), 3),
    ];
    let log = log(&records);
    let statuses: Vec<_> =
        log.iter().filter_map(|(_, m)| m.pointer("/params/update/status")).collect();
    assert_eq!(statuses, vec!["in_progress", "pending", "in_progress"], "{log:#?}");
    assert_eq!(content(&log[3].1), content(&snapshot("c", "a")));
}

#[test]
fn a_prompt_or_a_reused_call_id_stores_what_is_held_first() {
    let records = vec![
        ("in", "tool_call", start("0"), 0),
        ("in", "tool_call_update", snapshot("0", "first prompt"), 1),
        ("mux", "user_message", json!({"text": "again"}), 2),
        ("in", "tool_call", start("0"), 3),
        ("in", "tool_call_update", snapshot("0", "second prompt"), 4),
        ("in", "tool_call", start("0"), 5),
    ];
    let log = log(&records);
    let kinds: Vec<_> = log.iter().map(|(k, m)| (k.as_str(), content(m).is_some())).collect();
    assert_eq!(
        kinds,
        vec![
            ("tool_call", false),
            ("tool_call_update", false),
            ("tool_call_update", true),
            ("user_message", false),
            ("tool_call", false),
            ("tool_call_update", false),
            ("tool_call_update", true),
            ("tool_call", false),
        ]
    );
}

#[test]
fn a_turn_diff_is_stored_whole_once_per_turn() {
    let diff = |turn: &str, text: &str| json!({"jsonrpc": "2.0", "method": DIFF_KIND, "params": {"method": "turn/diff/updated", "params": {"turnId": turn, "diff": text}}});
    let records = vec![
        ("in", DIFF_KIND, diff("t1", "a"), 0),
        ("in", DIFF_KIND, diff("t1", "ab"), 1),
        ("in", DIFF_KIND, diff("t2", "c"), 2),
        ("mux", "turn_result", json!({}), 3),
    ];
    let log = log(&records);
    let whole: Vec<_> = log
        .iter()
        .filter_map(|(_, m)| m.pointer("/params/params/diff").and_then(Value::as_str))
        .collect();
    assert_eq!(whole, vec!["ab", "c"], "{log:#?}");
    assert_eq!(log.len(), 6);
    assert_eq!(log[0].1["params"][DIFF_NOTE], 1);
}

/// The PR's Performance table: each chat log under `ACPMUX_DEFERRAL_LOGS` (session folders,
/// `:`-separated) as this module would have stored it, and whether its transcript replays the same
/// at every record that is not the agent's stream and at the end. Run with
/// `ACPMUX_DEFERRAL_LOGS=... cargo test -p acpmux --release --lib -- --ignored --nocapture deferral_perf`.
#[test]
#[ignore = "a measurement, not a check"]
fn deferral_perf() {
    use crate::transcript::Transcript;
    let Ok(dirs) = std::env::var("ACPMUX_DEFERRAL_LOGS") else { return };
    let size = |r: &EventRecord| serde_json::to_string(r).unwrap().len() + 1;
    let apply =
        |t: &mut Transcript, r: &EventRecord| t.apply_event(&serde_json::to_value(r).unwrap());
    for dir in dirs.split(':') {
        let mut files: Vec<_> = std::fs::read_dir(Path::new(dir).join("events"))
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "ndjson"))
            .collect();
        files.sort();
        let mut deferral = Deferral::default();
        let (mut sent, mut kept) = (Transcript::default(), Transcript::default());
        // Bytes in and out, all and `tool_call_update` alone.
        let (mut bytes, mut tcu) = ([0usize; 2], [0usize; 2]);
        let (mut seq, mut calls, mut prompts, mut checks, mut differ) =
            (0u64, BTreeSet::new(), 0, 0, 0);
        let store = |r: EventRecord, side: usize, bytes: &mut [usize; 2], tcu: &mut [usize; 2]| {
            bytes[side] += size(&r);
            if r.kind == "tool_call_update" {
                tcu[side] += size(&r);
            }
            r
        };
        for file in files {
            for line in BufReader::new(File::open(file).unwrap()).lines() {
                let Ok(rec) = serde_json::from_str::<EventRecord>(&line.unwrap()) else { continue };
                if let Some(id) =
                    rec.msg.pointer("/params/update/toolCallId").and_then(Value::as_str)
                {
                    calls.insert(id.to_owned());
                }
                prompts += usize::from(rec.kind == "user_message" && rec.dir == "mux");
                let keep = deferral.keep(&rec.dir, &rec.kind, &rec.msg, rec.at, true);
                let mut out: Vec<EventRecord> = keep
                    .before
                    .into_iter()
                    .map(|(kind, msg)| EventRecord {
                        seq: 0,
                        at: rec.at,
                        dir: "in".into(),
                        kind: kind.into(),
                        msg,
                        host_seq: None,
                    })
                    .collect();
                let late = out.len();
                out.push(EventRecord {
                    msg: keep.stored.unwrap_or_else(|| rec.msg.clone()),
                    ..rec.clone()
                });
                for (i, mut r) in out.into_iter().enumerate() {
                    seq += 1;
                    r.seq = seq;
                    if i == late {
                        if !streams(&rec.dir, &rec.kind, &rec.msg) {
                            checks += 1;
                            differ += usize::from(sent.items != kept.items);
                        }
                        apply(
                            &mut sent,
                            &store(EventRecord { seq, ..rec.clone() }, 0, &mut bytes, &mut tcu),
                        );
                    }
                    apply(&mut kept, &store(r, 1, &mut bytes, &mut tcu));
                }
            }
        }
        for (kind, msg) in deferral.take_all() {
            seq += 1;
            let r = EventRecord {
                seq,
                at: 0,
                dir: "in".into(),
                kind: kind.into(),
                msg,
                host_seq: None,
            };
            apply(&mut kept, &store(r, 1, &mut bytes, &mut tcu));
        }
        let same_end = sent.items == kept.items;
        let mb = |b: usize| b as f64 / 1e6;
        let (n, p) = (calls.len().max(1) as f64, prompts.max(1) as f64);
        println!(
            "{dir}: log {:.1} -> {:.1} MB ({:+.0}%), tool_call_update {:.1} -> {:.1} MB, per call {:.1} -> {:.1} KB, per prompt {:.2} -> {:.2} MB; transcript differs at {differ} of {checks} checkpoints, same at end: {same_end}",
            mb(bytes[0]),
            mb(bytes[1]),
            100.0 * (mb(bytes[1]) - mb(bytes[0])) / mb(bytes[0]),
            mb(tcu[0]),
            mb(tcu[1]),
            tcu[0] as f64 / n / 1e3,
            tcu[1] as f64 / n / 1e3,
            mb(bytes[0]) / p,
            mb(bytes[1]) / p,
        );
    }
}

#[test]
fn a_snapshot_past_the_memory_caps_is_stored_whole() {
    let mut deferral = Deferral::default();
    let _ = deferral.keep("in", "tool_call", &start("big"), 0, true);
    let big = "o".repeat(MAX_HELD_BYTES + 1);
    assert!(
        deferral.keep("in", "tool_call_update", &snapshot("big", &big), 1, true).stored.is_none()
    );
    // Calls running side by side hold at most MAX_HELD_TOTAL between them.
    let part = "o".repeat(MAX_HELD_BYTES);
    let mut held = 0;
    for n in 0..16 {
        let id = format!("c{n}");
        let _ = deferral.keep("in", "tool_call", &start(&id), 0, true);
        held += usize::from(
            deferral
                .keep("in", "tool_call_update", &snapshot(&id, &part), 1, true)
                .stored
                .is_some(),
        );
    }
    assert_eq!(held, MAX_HELD_TOTAL / MAX_HELD_BYTES);
}

#[test]
fn records_the_store_refused_go_first_in_order() {
    let mut deferral = Deferral::default();
    let _ = deferral.keep("in", "tool_call", &start("a"), 0, true);
    let _ = deferral.keep("in", "tool_call", &start("b"), 0, true);
    let _ = deferral.keep("in", "tool_call_update", &snapshot("a", "a's"), 1, true);
    let _ = deferral.keep("in", "tool_call_update", &snapshot("b", "b's"), 1, true);
    // A status makes both due, and the store refuses them.
    let status = json!({"status": "idle"});
    let due = deferral.keep("mux", "status", &status, 2, true).before;
    assert_eq!(due.len(), 2);
    deferral.retry(due.clone());
    // The next record stores them first, in order, even the one it replaces.
    let of =
        |id: &str| due.iter().find(|(_, m)| m["params"]["update"]["toolCallId"] == id).cloned();
    let newer = snapshot("a", "a's newer");
    let next = deferral.keep("in", "tool_call_update", &newer, 3, true);
    assert_eq!(next.before, due);
    // Refused again, while the record after them is stored: the one it replaces is dropped.
    deferral.retry(next.before);
    deferral.stored("in", "tool_call_update", &newer);
    let last = deferral.keep("in", "tool_call_update", &snapshot("b", "b's newer"), 4, true);
    assert_eq!(last.before, vec![of("b").unwrap()]);
    // A fork copies what is held without taking it.
    let _ = deferral.keep("in", "tool_call_update", &snapshot("a", "newest"), 5, true);
    assert_eq!(deferral.pending().len(), 2, "a's newest and b's newer");
    assert_eq!(deferral.take_all().len(), 2);
}

#[test]
fn a_refused_record_is_dropped_once_a_record_that_replaces_it_is_stored() {
    let late = |text: &str| {
        let mut m = snapshot("c", text);
        m["params"]["update"].as_object_mut().unwrap().remove("_meta");
        ("tool_call_update", m)
    };
    let mut deferral = Deferral::default();
    // Its call id's next start, stored: the late output would read as the new call's.
    deferral.retry(vec![late("old")]);
    deferral.stored("in", "tool_call", &start("c"));
    assert!(deferral.take_all().is_empty());
    // Another call's start leaves it.
    deferral.retry(vec![late("old")]);
    deferral.stored("in", "tool_call", &start("d"));
    assert_eq!(deferral.take_all().len(), 1);
    // A newer update of its call with content replaces it; one without content does not.
    deferral.retry(vec![late("A")]);
    let status = update(
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed"}),
    );
    deferral.stored("in", "tool_call_update", &status);
    assert_eq!(deferral.take_all().len(), 1);
    deferral.retry(vec![late("A")]);
    deferral.stored("in", "tool_call_update", &snapshot("c", "B"));
    assert!(deferral.take_all().is_empty());
    // Until it is stored, a record that would replace it changes nothing: it goes first.
    deferral.retry(vec![late("A")]);
    let keep = deferral.keep("in", "tool_call_update", &snapshot("c", "B"), 1, false);
    assert_eq!(keep.before, vec![late("A")]);
}
