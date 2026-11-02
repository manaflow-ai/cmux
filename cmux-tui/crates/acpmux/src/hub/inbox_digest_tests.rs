//! The inbox digest's renderer (`inbox_digest.rs` `render`): its order, folding and budget.

use super::*;

impl PromptRun {
    fn clone_run(&self) -> PromptRun {
        PromptRun {
            size: Default::default(),
            blocks: self.blocks.clone(),
            display_parts: self.display_parts.clone(),
            control: self.control,
            trust_gate: self.trust_gate,
            provenance: self.provenance.clone(),
            agent: self.agent.clone(),
            class: self.class,
            supersede: self.supersede.clone(),
            full_access_device: self.full_access_device.clone(),
            message_id: self.message_id.clone(),
            message_sender: self.message_sender.clone(),
        }
    }
}

fn part(prompt_id: &str, name: &str, class: Class, at: u64, text: &str) -> Part {
    Part {
        prompt_id: prompt_id.into(),
        from: format!("acp:{name}"),
        from_name: name.into(),
        class,
        received_at: at,
        text: text.into(),
    }
}

fn at(text: &str, s: &str) -> usize {
    text.find(s).unwrap_or_else(|| panic!("{s:?} missing from {text}"))
}

#[test]
fn blocks_and_questions_come_first_then_results_by_sender_then_fyis() {
    let parts = [
        part("p1", "lane-b", Class::Result, 1, "b did one"),
        part("p2", "lane-a", Class::Fyi, 2, "heads up\nmore detail"),
        part("p3", "lane-a", Class::Question, 3, "which base?"),
        part("p4", "lane-a", Class::Result, 4, "a did one"),
        part("p5", "lane-c", Class::Block, 5, "blocked on CI"),
        part("p6", "lane-b", Class::Result, 6, "b did two"),
    ];
    let Rendered { text, provenance } = render("d1", &parts);
    assert!(text.starts_with("[inbox digest] 6 messages"), "{text}");
    assert!(text.contains("(1 block, 1 question, 3 results, 1 FYI)"), "{text}");
    assert!(at(&text, "[block] from lane-c, promptId p5") < at(&text, "[question] from lane-a"));
    assert!(at(&text, "which base?") < at(&text, "## Results"));
    // lane-b reported first, so its results come first, oldest first.
    assert!(at(&text, "### from lane-b") < at(&text, "b did one"));
    assert!(at(&text, "b did one") < at(&text, "b did two"));
    assert!(at(&text, "b did two") < at(&text, "### from lane-a"));
    assert!(at(&text, "a did one") < at(&text, "## FYIs"));
    assert!(text.ends_with("- lane-a (promptId p2): heads up…"), "{text}");
    assert_eq!(provenance["kind"], KIND);
    assert_eq!(provenance["digestId"], "d1");
    assert_eq!(provenance["counts"], json!({"block": 1, "question": 1, "result": 3, "fyi": 1}));
    let first = &provenance["parts"][0];
    assert_eq!(
        (first["promptId"].clone(), first["from"].clone(), first["fromName"].clone()),
        (json!("p1"), json!("acp:lane-b"), json!("lane-b"))
    );
    assert_eq!((first["class"].clone(), first["bytes"].clone()), (json!("result"), json!(9)));
}

#[test]
fn identical_texts_from_one_sender_fold_into_the_newest() {
    let parts = [
        part("p1", "lane-a", Class::Result, 1, "same"),
        part("p2", "lane-b", Class::Result, 2, "same"),
        part("p3", "lane-a", Class::Result, 3, "same"),
        part("p4", "lane-a", Class::Result, 4, "other"),
    ];
    let Rendered { text, provenance } = render("d", &parts);
    assert!(text.contains("[result] promptId p3 (×2)"), "{text}");
    assert!(!text.contains("promptId p1"), "{text}");
    assert!(text.contains("[result] promptId p2\n"), "another sender's copy stays: {text}");
    assert!(text.contains("Identical messages from one sender are folded"), "{text}");
    let parts = provenance["parts"].as_array().unwrap();
    assert_eq!(parts[0]["duplicateOf"], "p3");
    assert!(parts[1].get("duplicateOf").is_none() && parts[2].get("duplicateOf").is_none());
    assert_eq!(parts.len(), 4, "every original is listed");
}

#[test]
fn past_the_budget_a_part_shows_its_start_and_where_its_text_is() {
    let big = "x".repeat(DIGEST_MAX_BYTES - 10);
    let parts = [
        part("p1", "lane-a", Class::Result, 1, &big),
        part("p2", "lane-a", Class::Result, 2, &"y".repeat(1000)),
        part("p3", "lane-a", Class::Result, 3, "short"),
    ];
    let text = render("d", &parts).text;
    assert!(text.contains(&big));
    assert!(text.contains(&format!("{}…\n[full text: promptId p2]", "y".repeat(400))), "{text}");
    assert!(text.contains("short"), "a part no longer than the cut stays whole");
}

#[test]
fn an_fyi_is_its_first_line_up_to_160_characters() {
    assert_eq!(one_line("\n  hello  \n"), "hello");
    assert_eq!(one_line("one\ntwo"), "one…");
    assert_eq!(one_line(&"é".repeat(200)), format!("{}…", "é".repeat(160)));
}

/// A queue entry as `enqueue` makes it, from `agent` when given, of `class`.
fn queued(prompt_id: &str, agent: Option<&str>, class: Option<Class>, text: &str) -> QueuedPrompt {
    let run = PromptRun {
        size: Default::default(),
        blocks: vec![json!({"type": "text", "text": text})],
        display_parts: None,
        control: Control::Local,
        trust_gate: false,
        provenance: None,
        agent: agent.map(str::to_owned),
        class,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    };
    QueuedPrompt {
        prompt_id: prompt_id.into(),
        turn_id: format!("t-{prompt_id}"),
        client: "test".into(),
        preview: text.into(),
        queued_at: 7,
        withdraw: Arc::new(Notify::new()),
        run: Arc::new(run),
        restored: false,
        resume: false,
        steer: false,
        held: false,
        awaiting_owner: false,
        revision: 0,
        declined: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        sent_now: false,
        joined: Arc::new(StdMutex::new(None)),
        requeued: false,
        retries: 0,
    }
}

#[test]
fn a_part_takes_its_class_from_the_queue_entry_and_none_is_a_result() {
    let block = part_of(&queued("p1", Some("lane-a"), Some(Class::Block), "stuck"));
    assert_eq!(
        (block.class, block.from_name.as_str(), block.text.as_str()),
        (Class::Block, "lane-a", "stuck")
    );
    assert_eq!(block.from, "lane-a", "a sender with no address goes by its name");
    assert_eq!(block.received_at, 7);
    let plain = part_of(&queued("p2", Some("lane-b"), None, "done"));
    assert_eq!(plain.class, Class::Result);
}

#[test]
fn only_other_agents_text_messages_go_into_a_digest() {
    assert!(digestible(&queued("p1", Some("lane-a"), None, "hi")));
    assert!(!digestible(&queued("p2", None, None, "the person's")));
    assert!(!digestible(&queued("p3", Some("lane-a"), None, "/compact")), "a slash command");
    let mut sent_now = queued("p4", Some("lane-a"), None, "now");
    sent_now.sent_now = true;
    assert!(!digestible(&sent_now));
    let mut image = queued("p5", Some("lane-a"), None, "look");
    let mut run = image.run.clone_run();
    run.blocks.push(json!({"type": "image", "mimeType": "image/png", "data": "AAAA"}));
    image.run = Arc::new(run);
    assert!(!digestible(&image), "a message with an image goes alone");
    let mut digest = queued("p6", Some(SENDER), None, "an earlier digest");
    let mut run = digest.run.clone_run();
    run.provenance = Some(json!({"kind": KIND}));
    digest.run = Arc::new(run);
    assert!(!digestible(&digest));
    let mut web = queued("p7", Some("lane-a"), None, "from the web");
    let mut run = web.run.clone_run();
    run.control = Control::Web;
    web.run = Arc::new(run);
    assert!(!digestible(&web));
}

#[test]
fn a_restored_prompt_its_task_has_not_claimed_stays_queued() {
    let restored = queued("p1", Some("lane-a"), None, "from before the restart");
    let unclaimed = vec![("p1".to_owned(), "t-p1".to_owned())];
    assert!(!takes(&restored, &unclaimed), "none would hear the digest's answer for it");
    assert!(takes(&restored, &[]), "once claimed it goes in");
}

#[test]
fn a_digests_record_names_the_messages_it_took() {
    let parts =
        [part("p1", "lane-a", Class::Result, 1, "a"), part("p2", "lane-b", Class::Fyi, 2, "b")];
    let Rendered { provenance, .. } = render("d", &parts);
    let record = crate::prompt_provenance::marked(json!({"promptId": "d"}), Some(&provenance));
    assert_eq!(took(&record), ["p1", "p2"]);
    let other = json!({"promptId": "x", "_meta": {"provenance": {"kind": "agent_message", "parts": [{"promptId": "p1"}]}}});
    assert!(took(&other).is_empty());
}

/// A cmux agent message (`prompt_provenance.rs` `render`) wraps its words in an envelope that
/// names its sender: the digest shows the words, as the sidebar does (`prompt_line.rs`).
#[test]
fn a_cmux_agent_message_shows_its_words_not_its_envelope() {
    let envelope = "[cmux agent message] from builder (acp:a)\nMessage id: m-1\nNote\n---\n\
                    heads up: CI is slow\nmore\n--- end of message m-1 ---";
    let mut q = queued("p1", Some("builder"), Some(Class::Fyi), envelope);
    let mut run = q.run.clone_run();
    let from =
        json!({"kind": "agent_message", "from": "acp:a", "fromName": "builder", "msgId": "m-1"});
    run.provenance = Some(from);
    q.run = Arc::new(run);
    let part = part_of(&q);
    assert_eq!(part.text, "heads up: CI is slow\nmore");
    let text = render("d", &[part]).text;
    assert!(text.ends_with("- builder (promptId p1): heads up: CI is slow…"), "{text}");
}

/// A sender is its address: copies under a name it changed between them still fold, and its
/// results stay under one heading.
#[test]
fn a_renamed_sender_still_folds_and_groups_by_its_address() {
    let mut renamed = part("p2", "lane-a2", Class::Result, 2, "done");
    renamed.from = "acp:lane-a".into();
    let mut later = part("p3", "lane-a2", Class::Result, 3, "and more");
    later.from = "acp:lane-a".into();
    let parts = [part("p1", "lane-a", Class::Result, 1, "done"), renamed, later];
    let Rendered { text, .. } = render("d1", &parts);
    assert_eq!(text.matches("### from ").count(), 1, "{text}");
    assert_eq!(text.matches("\n\n[result]").count(), 2, "{text}");
    assert!(text.contains("promptId p2 (×2)"), "{text}");
}
