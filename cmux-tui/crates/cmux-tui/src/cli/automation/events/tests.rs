use super::*;

#[test]
fn a_pull_request_opened_after_the_start_is_an_event_once_in_any_state() {
    let pr = |n: u64, state: &str| {
        json!({"url": format!("https://github.com/o/r/pull/{n}"), "number": n, "title": format!("t{n}"),
                   "repository": {"nameWithOwner": "o/r"}, "isDraft": false, "state": state,
                   "createdAt": format!("2026-11-10T00:00:{n:02}Z")})
    };
    let mut cursor = PullRequestCursor::at("2026-11-10T00:00:03Z".into());
    // #2 is older than the start; #3 opened in the start's second.
    let fresh = cursor.advance(&[pr(2, "OPEN"), pr(3, "OPEN")]);
    assert_eq!(fresh.iter().map(|l| l["number"].as_u64().unwrap()).collect::<Vec<_>>(), [3]);
    assert!(cursor.advance(&[pr(3, "OPEN")]).is_empty(), "never twice");
    // #4 opened and merged between two reads, #5 still open: both, oldest first.
    let fresh = cursor.advance(&[pr(5, "OPEN"), pr(4, "MERGED"), pr(3, "CLOSED")]);
    let numbers: Vec<_> = fresh.iter().map(|l| l["number"].as_u64().unwrap()).collect();
    assert_eq!(numbers, [4, 5]);
    assert_eq!(fresh[0]["state"], "merged");
    assert_eq!(fresh[0]["event"], "pr-opened");
    assert_eq!(fresh[0]["repo"], "o/r");
    assert_eq!(cursor.since, "2026-11-10T00:00:05Z", "the next read starts at the newest");
    assert!(cursor.advance(&[pr(5, "CLOSED")]).is_empty());
}

#[test]
fn the_cursor_is_a_utc_time_to_the_second() {
    let now = utc_now();
    assert_eq!(now.len(), "2026-11-10T00:00:00Z".len(), "{now}");
    assert!(now.ends_with('Z') && now.as_bytes()[10] == b'T', "{now}");
}

fn own_sessions(
    names: &[(&'static str, &'static str)],
) -> (OwnSessions, std::rc::Rc<std::cell::Cell<u32>>) {
    let names = names.to_vec();
    let lookups = std::rc::Rc::new(std::cell::Cell::new(0));
    let counter = lookups.clone();
    let lookup = move |id: &str| {
        counter.set(counter.get() + 1);
        names.iter().find(|(known, _)| *known == id).map(|(_, name)| (*name).to_string())
    };
    (OwnSessions::new(Box::new(lookup)), lookups)
}

#[test]
fn an_automation_runs_own_session_starts_nothing() {
    let (mut own, _) = own_sessions(&[]);
    assert!(own.is_own(&json!({"agent_session": "auto-auto_abc-run_x", "state": "idle"})));
    assert!(own.is_own(&json!({"session_name": "auto-auto_abc-run_x"})));
    assert!(!own.is_own(&json!({"agent_session": "fix-login", "state": "idle"})));
    assert!(!own.is_own(&json!({"state": "idle"})));
}

#[test]
fn an_automations_own_chat_finishing_fires_nothing() {
    // A run is `acpmux run -n auto-...`; its chat's event carries the
    // session's id, which acpmux names.
    let (mut own, lookups) =
        own_sessions(&[("5f0c-run", "auto-auto_abc-run_x"), ("77aa-person", "fix-login")]);
    let idle = find("agent-idle").unwrap();
    let keep = |e: &Value| matches!(e["state"].as_str(), Some("idle" | "done"));
    let chat = |id: &str| json!({"kind": "agent", "change": "state", "source": "chat", "state": "idle", "agent_session": id});
    assert_eq!(
        line_for(idle, &chat("5f0c-run"), &keep, &mut own),
        None,
        "the run's own completion"
    );
    assert_eq!(line_for(idle, &chat("5f0c-run"), &keep, &mut own), None);
    assert_eq!(lookups.get(), 1, "each id is looked up once");
    let line =
        line_for(idle, &chat("77aa-person"), &keep, &mut own).expect("a person's chat fires");
    assert_eq!(line["event"], "agent-idle");
    // A permission prompt in the run's own chat (`agent-needs-input`).
    let dialog = json!({"kind": "dialog", "change": "opened", "agent_session": "5f0c-run"});
    assert!(own.is_own(&dialog));
    // An id acpmux does not know is someone else's.
    assert!(!own.is_own(&chat("unknown-id")));
}

#[test]
fn a_lookup_with_no_answer_is_asked_again() {
    // acpmux busy for one `info`: the next event from that run asks again
    // and is then known as the run's own.
    let answers = std::rc::Rc::new(std::cell::RefCell::new(vec![
        None,
        Some("auto-auto_abc-run_x".to_string()),
    ]));
    let calls = answers.clone();
    let mut own = OwnSessions::new(Box::new(move |_: &str| calls.borrow_mut().remove(0)));
    let chat = json!({"kind": "agent", "state": "idle", "agent_session": "5f0c-run"});
    assert!(!own.is_own(&chat), "no answer: not known to be a run's");
    assert!(own.is_own(&chat), "asked again, and now known");
    assert!(own.is_own(&chat), "remembered: no third lookup");
    assert!(answers.borrow().is_empty());
}

#[test]
fn an_event_line_names_its_event() {
    let kind = find("agent-idle").unwrap();
    let line = tagged(kind, &json!({"kind": "agent", "state": "idle"}));
    assert_eq!(line, json!({"event": "agent-idle", "kind": "agent", "state": "idle"}));
}

#[test]
fn every_event_has_a_source_here() {
    // A row added to the vocabulary without a source here would print
    // "no source": this names the arms `follow` matches.
    for e in EVENTS {
        assert!(
            matches!(e.name, "agent-idle" | "agent-needs-input" | "pr-opened"),
            "{} has no source in cli/automation/events.rs",
            e.name
        );
    }
}
