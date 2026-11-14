use super::*;

fn run(text: &str, agent: Option<&str>, provenance: Option<Value>) -> Arc<PromptRun> {
    Arc::new(PromptRun {
        size: Default::default(),
        blocks: vec![json!({"type": "text", "text": text})],
        display_parts: None,
        control: Control::default(),
        cloud_mobile: false,
        trust_gate: false,
        provenance,
        agent: agent.map(str::to_owned),
        class: None,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    })
}

#[test]
fn agent_messages_and_named_senders_are_agents_and_everything_else_is_the_person() {
    let message = json!({"kind": "agent_message", "from": "acp:s1", "fromName": "lane-a", "to": "acp:s2", "msgId": "m", "threadId": "t"});
    assert_eq!(agent_sender(Some(&message), None).as_deref(), Some("lane-a"));
    let sub = json!({"kind": "subsession_message", "from": "s1", "to": "s2"});
    assert_eq!(agent_sender(Some(&sub), None).as_deref(), Some("s1"));
    // Another session's message and a lane's task result card name the session they are from.
    let session = crate::prompt_provenance::session_message("s1", "lane-a", "s2");
    assert_eq!(agent_sender(Some(&session), None).as_deref(), Some("lane-a"));
    let card = crate::prompt_provenance::task_result("s1", "lane-b", "s2", "t-1", "done");
    assert_eq!(agent_sender(Some(&card), None).as_deref(), Some("lane-b"));
    assert_eq!(agent_sender(None, Some("coord-deputy")).as_deref(), Some("coord-deputy"));
    // One the person edited is theirs, after a restart too; it still names its sender.
    let edited =
        json!({"kind": "agent_message", "fromName": "lane-a", "editedBy": {"actor": "owner"}});
    assert_eq!(agent_sender(Some(&edited), None), None);
    assert_eq!(named_sender(Some(&edited)).as_deref(), Some("lane-a"));
    // A queue listing keeps it, and an unverified prompt's, to draw; none for the others.
    assert_eq!(listed_provenance(Some(&edited), None), Some(edited.clone()));
    let unverified = crate::prompt_provenance::unverified("s2", "unix", Default::default());
    assert_eq!(listed_provenance(Some(&unverified), None), Some(unverified.clone()));
    assert_eq!(listed_provenance(Some(&message), Some("lane-a")), None);
    assert_eq!(listed_provenance(Some(&message), None), None);
    assert_eq!(agent_sender(None, None), None, "a plain prompt is the person's");
    let resume = json!({"kind": "auto_resume", "promptId": "p", "attempt": 1, "turnId": "t"});
    assert_eq!(agent_sender(Some(&resume), None), None, "a continuation is the person's");
    let offer =
        json!({"kind": "offer_result", "offerId": "o", "childSessionId": "c", "title": "t"});
    assert_eq!(agent_sender(Some(&offer), None), None);
}

#[test]
fn from_agent_is_one_short_line() {
    let named = |v: Value| declared_sender(&json!({"_meta": {"acpmux": {"fromAgent": v}}}));
    assert_eq!(named(json!(" lane-a ")).unwrap().as_deref(), Some("lane-a"));
    assert_eq!(named(Value::Null).unwrap(), None);
    assert!(named(json!("")).is_err());
    assert!(named(json!("two\nlines")).is_err());
    assert!(named(json!("x".repeat(65))).is_err());
    assert!(named(json!(7)).is_err());
    assert_eq!(declared_sender(&json!({})).unwrap(), None);
}

#[test]
fn a_digest_keeps_every_message_whole_and_in_order_under_its_sender() {
    let parts = vec![
        Part {
            prompt_id: "p1".into(),
            sender: "lane-a".into(),
            run: run("first\nline two", Some("lane-a"), None),
        },
        Part {
            prompt_id: "p2".into(),
            sender: "lane-b".into(),
            run: run("second", Some("lane-b"), None),
        },
        Part {
            prompt_id: "p3".into(),
            sender: "lane-a".into(),
            run: run("third", Some("lane-a"), None),
        },
    ];
    let text = prompt_text(&digest_blocks(&parts));
    let at = |s: &str| text.find(s).unwrap_or_else(|| panic!("{s:?} missing from {text}"));
    assert!(text.starts_with("3 messages from other agents arrived while you were busy."));
    assert!(at("[agent message 1 of 3] from lane-a") < at("first\nline two"));
    assert!(at("first\nline two") < at("[agent message 2 of 3] from lane-b"));
    assert!(at("[agent message 2 of 3] from lane-b") < at("second"));
    assert!(at("second") < at("[agent message 3 of 3] from lane-a"));
    assert!(at("[agent message 3 of 3] from lane-a") < at("third"));
    let provenance = digest_provenance(&parts);
    assert_eq!(provenance["kind"], DIGEST_KIND);
    let senders: Vec<&str> = provenance["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["from"].as_str().unwrap())
        .collect();
    assert_eq!(senders, ["lane-a", "lane-b", "lane-a"]);
}

/// A message put back after a failed turn keeps its display parts (each attachment's source)
/// in its `requeued` record, so a restart restores them with it.
#[tokio::test]
async fn a_requeued_message_keeps_its_attachments_source_across_a_restart() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Arc::new(Hub::new(config, store));
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "requeue-sourced", "name": "requeue",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta.clone());
    let source = json!({"name": "Finder", "bundleId": "com.apple.finder"});
    let display = json!([{"kind": "file", "blockIndex": 1, "name": "notes.txt", "source": source}]);
    let run = PromptRun {
        size: Default::default(),
        blocks: vec![
            json!({"type": "text", "text": "see the notes"}),
            json!({"type": "resource_link", "name": "notes.txt", "uri": "file:///tmp/notes.txt"}),
        ],
        display_parts: Some(display.clone()),
        control: Control::default(),
        cloud_mobile: false,
        trust_gate: false,
        provenance: None,
        agent: Some("lane-a".into()),
        class: None,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    };
    let digest = DigestTurn::default();
    *digest.taken.lock().unwrap() = vec![QueuedPrompt {
        prompt_id: "p1".into(),
        turn_id: "t-p1".into(),
        client: "test".into(),
        preview: "see the notes".into(),
        queued_at: 7,
        withdraw: Arc::new(tokio::sync::Notify::new()),
        run: Arc::new(run),
        restored: false,
        resume: false,
        steer: false,
        held: false,
        awaiting_owner: false,
        revision: 0,
        declined: Default::default(),
        sent_now: false,
        joined: Arc::new(StdMutex::new(None)),
        requeued: false,
        retries: 0,
    }];
    hub.requeue_joined(&session, &digest, false);

    // The daemon starts again: the chat's queue comes back from its log.
    let restarted = hub.make_session(meta);
    hub.restore_queue(&restarted);
    let queue = restarted.queue.lock().unwrap();
    let back =
        queue.iter().find(|q| q.prompt_id == "p1").expect("the requeued message is queued again");
    assert_eq!(back.run.display_parts.as_ref(), Some(&display));
    assert_eq!(back.run.display_parts.as_ref().unwrap()[0]["source"], source);
}

fn waiting(id: &str, text: &str) -> QueuedPrompt {
    QueuedPrompt {
        prompt_id: id.into(),
        turn_id: format!("t-{id}"),
        client: "test".into(),
        preview: text.into(),
        queued_at: 7,
        withdraw: Arc::new(tokio::sync::Notify::new()),
        run: run(text, Some("lane-a"), None),
        restored: false,
        resume: false,
        steer: false,
        held: false,
        sent_now: false,
        joined: Arc::new(StdMutex::new(None)),
        requeued: false,
        retries: 0,
        awaiting_owner: false,
        revision: 0,
        declined: Default::default(),
    }
}

/// What an inbox digest took is charged to the chat's queue until it goes back in, and the
/// charge goes in the critical section that puts it back, once, however often it is released
/// (manaflow-ai/cmux#28768 review: no interval where the bytes are in neither place).
#[tokio::test]
async fn a_digest_charge_moves_with_its_messages_and_is_released_once() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Arc::new(Hub::new(config, store));
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "digest-charge", "name": "charge",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    let taken = vec![waiting("p1", "first"), waiting("p2", "second message")];
    let bytes: u64 = taken.iter().map(|q| super::super::queue_admission::run_bytes(&q.run)).sum();
    assert!(bytes > 0);
    let digest = DigestTurn::default();
    {
        let queue = session.queue.lock().unwrap();
        digest.charge(&session, &queue, &taken);
    }
    *digest.taken.lock().unwrap() = taken;
    assert_eq!(session.digest_bytes.load(Ordering::SeqCst), bytes);

    // A failed turn puts them back: the queue holds them, the charge is gone.
    hub.requeue_joined(&session, &digest, false);
    assert_eq!(session.queue.lock().unwrap().len(), 2);
    assert_eq!(session.digest_bytes.load(Ordering::SeqCst), 0);

    // Released again (the digest's task ends after): nothing more comes off.
    let other = DigestTurn::default();
    {
        let queue = session.queue.lock().unwrap();
        other.charge(&session, &queue, &[waiting("p3", "third")]);
        digest.release(&session, &queue);
    }
    assert!(session.digest_bytes.load(Ordering::SeqCst) > 0);
    {
        let queue = session.queue.lock().unwrap();
        other.release(&session, &queue);
        other.release(&session, &queue);
    }
    assert_eq!(session.digest_bytes.load(Ordering::SeqCst), 0);
}
