use super::*;

fn link(out: mpsc::UnboundedSender<Out>, write: OwnedWriteHalf) -> Link {
    let mut link = Link::new(("s", "g"), 1, out, write, Held::default());
    link.next_id = 2;
    link
}
/// A record the daemon sends before the attach answer reaches the room after the snapshot.
#[test]
fn records_before_the_attach_answer_follow_the_snapshot() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
        let (_read, write) = ours.into_split();
        let (out, mut frames) = mpsc::unbounded_channel();
        let mut link = link(out, write);
        link.pending.insert(1, Pending::Attach);
        let record = json!({"event": "agent-session-record",
            "record": {"seq": 5, "kind": "agent_message"}});
        assert!(link.inbound(&record.to_string()).await);
        let reply = json!({"id": 1, "ok": true, "data": {"events": [{"seq": 4}]}});
        assert!(link.inbound(&reply.to_string()).await);
        let mut kinds = Vec::new();
        while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
            kinds.push(frame["t"].clone());
        }
        assert_eq!(kinds, vec![json!("snapshot"), json!("records")]);
    });
}

/// A person's prompt reaches every guest page with its sender: the `user_message` record goes
/// to the room whole, its `person_message` provenance (`fromName`, `fromAvatar`) included,
/// so a guest page draws it as from that person (ask-2a1105b933).
#[test]
fn a_persons_message_reaches_the_guests_with_its_sender() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
        let (_read, write) = ours.into_split();
        let (out, mut frames) = mpsc::unbounded_channel();
        let mut link = link(out, write);
        link.pending.insert(1, Pending::Attach);
        let reply = json!({"id": 1, "ok": true, "data": {"events": []}});
        assert!(link.inbound(&reply.to_string()).await);
        let record = json!({"seq": 7, "kind": "user_message", "msg": {"text": "hi",
            "promptId": "g-x", "_meta": {"provenance": {"kind": "person_message",
                "from": "guest:s.g2", "fromName": "Sam Park",
                "fromAvatar": "https://lh3.example.com/a/sam.png", "approval": "owner"}}}});
        let live = json!({"event": "agent-session-record", "record": record});
        assert!(link.inbound(&live.to_string()).await);
        let mut relayed = None;
        while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
            if frame["t"] == "records" {
                relayed = Some(frame["records"][0].clone());
            }
        }
        assert_eq!(relayed, Some(record), "the record reaches the room whole");
    });
}

/// Records before the attach answer are cut and bounded by bytes: big ones end the relay
/// (its next one starts from a fresh snapshot) instead of filling memory.
#[test]
fn records_before_the_attach_answer_are_bounded_by_bytes() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
        let (_read, write) = ours.into_split();
        let (out, _frames) = mpsc::unbounded_channel();
        let mut link = link(out, write);
        link.pending.insert(1, Pending::Attach);
        let big = "x".repeat(MAX_RECORD - 1024);
        let mut open = true;
        let mut sent = 0;
        while open && sent < MAX_EARLY {
            let record = json!({"event": "agent-session-record",
                "record": {"seq": sent, "kind": "agent_message", "text": big}});
            open = link.inbound(&record.to_string()).await;
            sent += 1;
        }
        assert!(!open, "the relay ends past the byte budget");
        assert!(sent < MAX_EARLY, "by bytes, before the count: {sent}");
        assert!(link.early_bytes > MAX_EARLY_BYTES);
        // A huge record is kept cut, never whole.
        let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
        let (_read, write) = ours.into_split();
        let (out, _frames) = mpsc::unbounded_channel();
        let mut link = tests::link(out, write);
        let huge = json!({"event": "agent-session-record",
            "record": {"seq": 1, "kind": "agent_message", "text": "y".repeat(2 * MAX_RECORD)}});
        assert!(link.inbound(&huge.to_string()).await);
        assert!(link.early_bytes < 1024);
        assert_eq!(link.early[0].0["truncated"], json!(true));
    });
}

/// A prompt the room sends before the attachment, past the cap, is refused and said.
#[test]
fn a_prompt_before_the_attachment_past_the_cap_is_refused() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
        let (_read, write) = ours.into_split();
        let (out, mut frames) = mpsc::unbounded_channel();
        let mut link = link(out, write);
        for n in 0..MAX_HELD {
            assert!(link.take(format!("c{n}"), "hi".into()).is_some());
        }
        assert!(link.take("over".into(), "hi".into()).is_none());
        let mut states = Vec::new();
        while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
            states.push((
                frame["client_id"].clone(),
                frame["state"].clone(),
                frame["reason"].clone(),
            ));
        }
        assert_eq!(states, vec![(json!("over"), json!("refused"), json!("share.too_many_held"))]);
    });
}

/// The client ids the ledger forgets first are never a prompt still counted (held, or sent
/// and unanswered), so its later state still reaches the guest.
#[test]
fn the_client_id_of_a_counted_prompt_is_kept() {
    let mut ledger = Ledger::default();
    assert!(ledger.take("g-held", "c-held".into(), "hi".into()));
    for n in 0..(MAX_CLIENTS * 2) {
        ledger.remember(&format!("g-asked{n}"), format!("c{n}"));
    }
    assert_eq!(ledger.clients.len(), MAX_CLIENTS);
    assert!(ledger.note("g-held", "approved", None));
    let frame = ledger.frame("g", "g-held").expect("its client id is kept");
    assert_eq!(frame["client_id"], json!("c-held"));
    assert_eq!(frame["state"], json!("approved"));
}

/// A guest prompt's queued and decided records that come before the attach answer, too big
/// and so kept cut, still move its state (held, then approved or declined) and free its slot.
#[test]
fn decisions_in_cut_records_before_the_attach_answer_still_count() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let (ours, _theirs) = tokio::net::UnixStream::pair().unwrap();
        let (_read, write) = ours.into_split();
        let (out, mut frames) = mpsc::unbounded_channel();
        let mut link = link(out, write);
        link.pending.insert(1, Pending::Attach);
        let mut prompts = Vec::new();
        for n in 0..MAX_HELD {
            prompts.push(link.take(format!("c{n}"), "hi".into()).expect("under the cap"));
        }
        let big = "z".repeat(2 * MAX_RECORD);
        let records = [
            (5, "queued", &prompts[0]),
            (6, "queue_approved", &prompts[0]),
            (7, "queued", &prompts[1]),
            (8, "queue_declined", &prompts[1]),
        ];
        for (seq, kind, prompt) in records {
            let record = json!({"event": "agent-session-record", "record": {"seq": seq,
                "kind": kind, "msg": {"promptId": prompt, "awaitingOwner": true, "text": big}}});
            assert!(link.inbound(&record.to_string()).await);
        }
        let reply = json!({"id": 1, "ok": true, "data": {"events": [{"seq": 4}]}});
        assert!(link.inbound(&reply.to_string()).await);
        let mut states = Vec::new();
        while let Ok(Out::Frame(_, _, frame)) = frames.try_recv() {
            if frame["t"] == json!("prompt_state") {
                states.push((frame["client_id"].clone(), frame["state"].clone()));
            }
        }
        assert_eq!(
            states,
            vec![
                (json!("c0"), json!("held")),
                (json!("c0"), json!("approved")),
                (json!("c1"), json!("held")),
                (json!("c1"), json!("declined")),
            ]
        );
        // Their two slots are free again, and no more.
        assert!(link.take("over1".into(), "hi".into()).is_some());
        assert!(link.take("over2".into(), "hi".into()).is_some());
        assert!(link.take("over3".into(), "hi".into()).is_none());
    });
}
