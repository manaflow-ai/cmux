use serde_json::{Map, Value, json};

use super::super::{File, save};
use super::*;

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn saved(file: &mut File, key: &str, value: Value) -> String {
    let (saved, _) = save(file, "/r", key, fields(value)).unwrap();
    saved["comment"]["id"].as_str().unwrap().to_owned()
}

fn thread_change(file: &mut File, key: &str, value: Value) -> Value {
    let change = change(&fields(value)).unwrap();
    apply(file, "/r", key, change, "2026-11-24T00:00:00.000Z").unwrap().0
}

#[test]
fn a_change_is_checked() {
    let refused = |value: Value| change(&fields(value)).unwrap_err().code;
    assert_eq!(refused(json!({"id": "dc_1"})), "validation.invalid", "nothing to change");
    assert_eq!(refused(json!({"reply": "x"})), "validation.invalid", "no id");
    assert_eq!(refused(json!({"id": "dc_1", "reply": "  "})), "validation.invalid");
    assert_eq!(refused(json!({"id": "dc_1", "reply": "x", "author": "bot"})), "validation.invalid");
    assert_eq!(refused(json!({"id": "dc_1", "resolved": "yes"})), "validation.invalid");
    let long = "x".repeat(MAX_REPLY_BYTES + 1);
    assert_eq!(refused(json!({"id": "dc_1", "reply": long})), "validation.invalid");
    let ok = change(&fields(json!({"id": "dc_1", "reply": "x", "author": "agent"}))).unwrap();
    assert!(matches!(ok.reply, Some((Author::Agent, _))));
}

#[test]
fn replies_and_resolves_stay_through_a_page_save() {
    let mut file = File::default();
    let id = saved(&mut file, "k1", json!({"filePath": "a.rs", "message": "fix"}));
    let replied =
        thread_change(&mut file, "r1", json!({"id": id, "reply": "done", "author": "agent"}));
    let reply = &replied["comment"]["replies"][0];
    assert_eq!(reply["author"], "agent");
    assert!(reply["id"].as_str().unwrap().starts_with("dr_"), "{reply}");
    let resolved = thread_change(&mut file, "r2", json!({"id": id, "resolved": true}));
    assert_eq!(resolved["comment"]["resolved"], true);
    assert!(resolved["comment"]["resolvedAt"].is_string());
    // The page knows no thread: its save keeps the stored one.
    let page =
        json!({"id": id, "filePath": "a.rs", "message": "fix", "replies": [], "resolved": false});
    saved(&mut file, "k2", page);
    let kept = &file.comments[0];
    assert_eq!(kept["replies"].as_array().unwrap().len(), 1);
    assert_eq!(kept["resolved"], true);
    let reopened = thread_change(&mut file, "r3", json!({"id": id, "resolved": false}));
    assert!(reopened["comment"].get("resolvedAt").is_none(), "{reopened}");
    let missing = change(&fields(json!({"id": "nope", "resolved": true}))).unwrap();
    let error = apply(&mut file, "/r", "r4", missing, "now").unwrap_err();
    assert_eq!(error.details["reason"], "no_comment", "{error:?}");
}

#[test]
fn a_threaded_prompt_carries_only_what_the_agent_has_not_read() {
    let mut file = File::default();
    let a = saved(
        &mut file,
        "k1",
        json!({"filePath": "src/lib.rs", "startLine": 5, "endLine": 8, "message": "split",
               "submissionText": "Review comment on src/lib.rs lines 5-8:\n\nsplit\n"}),
    );
    let b = saved(
        &mut file,
        "k2",
        json!({"filePath": "src/main.rs", "startLine": 2, "endLine": 2,
                                          "lineText": "run();", "message": "handle it"}),
    );
    let ids = [a.clone(), b.clone()];
    let (text, carried) = render(&file, "/r o'ot", &ids, Some("please look")).unwrap();
    assert!(text.starts_with("Code review of /r o'ot: 2 threads across 2 files."), "{text}");
    assert!(text.contains(r"--root '/r o'\''ot'"), "{text}");
    assert!(text.contains("The reviewer's note: please look"), "{text}");
    assert!(text.contains(&format!("## Thread {a}: src/lib.rs lines 5-8 (new version)")), "{text}");
    assert!(text.contains(&format!("## Thread {b}: src/main.rs line 2")), "{text}");
    assert!(text.contains("> run();"), "{text}");
    assert_eq!(mark_sent(&mut file, &carried, "p1"), ids.to_vec());
    assert!(render(&file, "/r", &ids, None).is_none(), "all read");

    // The agent answers; that is not news for the agent.
    thread_change(&mut file, "r1", json!({"id": a, "reply": "split it", "author": "agent"}));
    assert!(render(&file, "/r", &ids, None).is_none());
    // The reviewer answers back in a and resolves b.
    thread_change(&mut file, "r2", json!({"id": a, "reply": "not yet"}));
    thread_change(&mut file, "r3", json!({"id": b, "resolved": true}));
    let (text, carried) = render(&file, "/r", &ids, None).unwrap();
    assert!(text.starts_with("Code review of /r: 2 threads across 2 files."), "{text}");
    assert!(
        text.contains("Earlier in this thread:\n- reviewer: split\n- agent: split it\n"),
        "{text}"
    );
    assert!(text.contains("New from the reviewer:\n- not yet\n"), "{text}");
    assert!(text.contains("resolved this thread; it needs no answer"), "{text}");
    mark_sent(&mut file, &carried, "p2");
    assert!(render(&file, "/r", &ids, None).is_none(), "all read again");
    let replies = file.comments.iter().find(|c| c["id"] == json!(a)).unwrap()["replies"].clone();
    assert_eq!(replies[1]["sentIn"], "p2", "{replies}");
    assert!(replies[0].get("sentIn").is_none(), "an agent's reply is never sent back");
    // A comment edited while its send was in flight stays unread.
    let c = saved(&mut file, "k3", json!({"filePath": "x.rs", "message": "one"}));
    let (_, carried) = render(&file, "/r", &[c.clone()], None).unwrap();
    saved(&mut file, "k4", json!({"id": c, "filePath": "x.rs", "message": "two"}));
    mark_sent(&mut file, &carried, "p3");
    assert!(render(&file, "/r", &[c], None).is_some());
}

#[test]
fn a_browser_or_terminal_thread_names_its_surface_not_a_file() {
    let mut file = File::default();
    let a = saved(
        &mut file,
        "k1",
        json!({"surface": "terminal", "place": "zsh (~/w)", "quote": "error: x", "message": "why",
               "submissionText": "> **Terminal**\n> error: x\n\nwhy"}),
    );
    let b = saved(
        &mut file,
        "k2",
        json!({"surface": "browser", "place": "https://example.com/", "message": "too wide"}),
    );
    let (text, _) = render(&file, "/r", &[a.clone(), b.clone()], None).unwrap();
    assert!(text.starts_with("Code review of /r: 2 threads across 2 places."), "{text}");
    assert!(
        text.contains(&format!("## Thread {a}: terminal zsh (~/w)\n\n> **Terminal**")),
        "{text}"
    );
    assert!(
        text.contains(&format!("## Thread {b}: browser page https://example.com/\n")),
        "{text}"
    );
    assert!(text.contains("too wide"), "{text}");
    assert!(!text.contains("(no file)") && !text.contains("new version"), "{text}");
}
