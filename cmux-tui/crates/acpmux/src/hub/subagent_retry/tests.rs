use super::*;

#[test]
fn the_prompt_names_the_agent_and_says_to_resume_it() {
    let text = retry_text(Some("Push relay"), "a8e1b68b93aac9d16", "API Error: 503");
    assert!(text.contains("\"Push relay\" (agent id a8e1b68b93aac9d16)"), "{text}");
    assert!(text.contains("SendMessage to \"a8e1b68b93aac9d16\""), "{text}");
    assert!(text.contains("only if that resume fails"), "{text}");
    let long = "x".repeat(1000);
    assert!(retry_text(None, "a", &long).len() < 700);
}

#[test]
fn a_queue_list_names_a_resume_by_its_provenance_and_nothing_else() {
    let p = json!({"kind": PROVENANCE_KIND, "subagentId": "s/t2", "agentId": "a8e1", "attempt": 1,
            "name": "Push \"relay\"", "error": "API Error: 503"});
    let resume = listed(Some(&p)).expect("a resume");
    assert_eq!(resume.agent_id, "a8e1");
    assert_eq!(resume.name.as_deref(), Some("Push \"relay\""));
    assert_eq!(resume.error.as_deref(), Some("API Error: 503"));
    // An older record with no name or error still names the agent.
    let bare =
        json!({"kind": PROVENANCE_KIND, "subagentId": "s/t2", "agentId": "a8e1", "attempt": 1});
    assert_eq!(listed_name(&bare), (Some("a8e1".to_owned()), None));
    // The person's prompt (no provenance, or a teammate's) and an agent's message are none.
    assert!(listed(None).is_none());
    assert!(listed(Some(&json!({"kind": "person_message", "from": "u-2"}))).is_none());
    assert!(listed(Some(&json!({"kind": "agent_message", "from": "acp:x"}))).is_none());
}

fn listed_name(p: &Value) -> (Option<String>, Option<String>) {
    let l = listed(Some(p));
    (l.as_ref().map(|l| l.agent_id.clone()), l.and_then(|l| l.name))
}

/// A retry prompt skipped after it went out never starts; others start, the same prompt
/// id in another chat too.
#[test]
fn a_skipped_retry_prompt_never_starts() {
    let retries = Retries::default();
    let key = ("s1".to_owned(), "p".to_owned());
    retries.lock().sent.insert(key.clone(), false);
    let mut started = false;
    retries.start("s1", "p", true, || started = true).unwrap();
    assert!(started);
    retries.lock().sent.insert(key, true);
    let mut again = false;
    let refused = retries.start("s1", "p", true, || again = true).unwrap_err();
    assert!(!again);
    assert_eq!(refused.data.unwrap()["reason"], "subagent_retry.skipped");
    retries.start("s1", "other", false, || {}).unwrap();
    let mut elsewhere = false;
    retries.start("s2", "p", false, || elsewhere = true).unwrap();
    assert!(elsewhere, "another chat's prompt of the same id starts");
    // A retry prompt no attempt here sent (a restart restored it) never starts.
    let mut restored = false;
    let refused = retries.start("s2", "p", true, || restored = true).unwrap_err();
    assert!(!restored);
    assert_eq!(refused.data.unwrap()["reason"], "subagent_retry.skipped");
}

/// Past the limit the oldest stopped or given-up failures go; a waiting one stays.
#[test]
fn failed_subagents_past_the_limit_forget_only_the_oldest() {
    let failed = |at: u64, waiting: bool| Sub {
        failed: Some(Failure {
            agent_id: format!("a{at}"),
            error: String::new(),
            reason: "capacity",
            at,
            idle: !waiting,
            wait: waiting.then(|| Wait {
                attempt: 1,
                of: 1,
                next_at: 0,
                prompt_id: String::new(),
                wake: Arc::new(Notify::new()),
                fired: false,
                fired_at: 0,
                manual: false,
            }),
        }),
        ..Sub::default()
    };
    let mut subs: HashMap<String, Sub> = HashMap::new();
    subs.insert("waiting".into(), failed(0, true));
    for at in 1..=(MAX_FAILED as u64 + 2) {
        subs.insert(format!("s{at}"), failed(at, false));
    }
    let mut gone: Vec<String> = forget_oldest(&mut subs).into_iter().map(|(id, _)| id).collect();
    gone.sort();
    assert_eq!(gone, ["s1", "s2"]);
    assert_eq!(subs.len(), MAX_FAILED + 1);
    assert!(subs.contains_key("waiting"));
    assert!(forget_oldest(&mut subs).is_empty());
}
