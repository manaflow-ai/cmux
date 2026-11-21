//! Receiver admission replay. The private trace stays outside the repository. A bypass is an
//! immediate-path admission, not a rendered chat row: the renderer and triage have separate tests.
use super::*;
use serde::Deserialize;
use std::collections::BTreeSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Trace {
    reply_timeline: Vec<EventRecord>,
    arrivals: Vec<Arrival>,
    protected_ids: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Arrival {
    at: u64,
    prompt_id: String,
    sender_id: String,
    class: PromptClass,
    person: bool,
    provenance: Value,
    blocks: Vec<Value>,
    thread: Option<String>,
}

fn replay(trace: Trace) -> (usize, usize) {
    assert_eq!(trace.arrivals.len(), 378);
    let senders: BTreeSet<_> = trace.arrivals.iter().map(|a| &a.sender_id).collect();
    assert_eq!(senders.len(), 86);
    assert!(trace.arrivals.windows(2).all(|pair| pair[0].at <= pair[1].at));
    assert!(!trace.reply_timeline.is_empty(), "missing measured receiver history");
    assert!(trace.reply_timeline.windows(2).all(|p| p[0].at <= p[1].at));
    let mut timeline = trace.reply_timeline.into_iter().peekable();
    let (hub, session) = hub_with_chat("replay");
    let mut admitted = BTreeSet::new();
    let mut held = BTreeSet::new();
    let mut protected_by_kind: [BTreeSet<String>; 4] = Default::default();
    for a in trace.arrivals {
        // Check the source fields independently of the exporter's expected-ID manifest.
        // A missing question in that manifest must fail even if the gate held it.
        for (ids, protected) in protected_by_kind.iter_mut().zip([
            a.provenance.pointer("/notice/severity").and_then(Value::as_str) == Some("fire"),
            a.class == PromptClass::Question,
            a.class == PromptClass::Block,
            a.person,
        ]) {
            if protected {
                ids.insert(a.prompt_id.clone());
            }
        }
        {
            let mut state = session.time_breakdown.lock().unwrap();
            while timeline.peek().is_some_and(|event| event.at <= a.at) {
                let mut event = timeline.next().unwrap();
                // Sequence numbers belong to the replay store; timestamps belong to the source.
                event.seq = state.last_seq() + 1;
                state.record(&event);
            }
        }
        let opts = PromptOptions {
            class: Some(a.class),
            human_authenticated: a.person,
            agent: (!a.person).then_some(a.sender_id),
            provenance: (!a.provenance.is_null()).then_some(a.provenance),
            thread: a.thread,
            ..Default::default()
        };
        let receipt = hub
            .hold_surge_message(&session, &a.prompt_id, "replay", &a.blocks, &opts, a.at)
            .unwrap();
        if let Some(receipt) = receipt {
            assert_eq!(receipt["promptId"], a.prompt_id);
            assert_eq!(receipt["surgeHeld"], true);
            assert!(held.insert(a.prompt_id));
        } else {
            assert!(admitted.insert(a.prompt_id));
        }
    }
    assert!(held.is_disjoint(&admitted));
    assert_eq!(held.len() + admitted.len(), 378, "prompt IDs must identify distinct arrivals");
    let required: BTreeSet<_> = protected_by_kind.iter().flatten().cloned().collect();
    assert!(
        required.is_subset(&trace.protected_ids),
        "source urgency missing from manifest: {:?}",
        required.difference(&trace.protected_ids).collect::<Vec<_>>()
    );
    assert!(
        trace.protected_ids.is_subset(&admitted),
        "protected IDs held or missing: {:?}",
        trace.protected_ids.difference(&admitted).collect::<Vec<_>>()
    );
    let original_ids: BTreeSet<_> = hub
        .events(&session.id, 0, 100_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "inbox" && e.msg["surgeHeld"] == true)
        .map(|e| e.msg["promptId"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(original_ids, held);
    assert_eq!(hub.inbox_threads(&session)["surge"]["held"], held.len());
    println!(
        "arrivals=378 senders=86 held={} immediate_path={} protected={} fire={} questions={} blocks={} person={}",
        held.len(),
        admitted.len(),
        trace.protected_ids.len(),
        protected_by_kind[0].len(),
        protected_by_kind[1].len(),
        protected_by_kind[2].len(),
        protected_by_kind[3].len()
    );
    (held.len(), admitted.len())
}

#[tokio::test]
async fn synthetic_surge_flood_preserves_every_protected_id() {
    let reply_timeline = [(1, 1, "turn_started"), (2, 60_001, "turn_result")]
        .into_iter()
        .map(|(seq, at, kind)| EventRecord {
            seq,
            at,
            dir: "mux".into(),
            kind: kind.into(),
            msg: json!({"turnId":"finished","turnSeq":1,"status":"completed"}),
            host_seq: None,
        })
        .collect();
    let arrivals = (0..378).map(|i| {
        let sender = format!("vm-{}", i % 86);
        let notice = json!({"sender":sender,"title":"#123 on runner label linux queued with no runner",
            "severity": if i == 153 {"fire"} else {"warn"}});
        Arrival {
            at: 61_000 + i * 8_000, prompt_id: i.to_string(), sender_id: sender,
            class: match i { 55 => PromptClass::Question, 89 => PromptClass::Block, _ => PromptClass::Fyi },
            person: i == 204, provenance: crate::prompt_provenance::notice(&notice, "replay"),
            blocks: vec![json!({"type":"text","text":"check this runner"})], thread: None,
        }
    }).collect();
    let trace = Trace {
        arrivals,
        reply_timeline,
        protected_ids: [55, 89, 153, 204].map(|n| n.to_string()).into(),
    };
    assert_eq!(replay(trace), (373, 5));
}

#[tokio::test]
async fn surge_hold_at_the_prompt_entry_point_has_no_second_chat_row_on_retry() {
    let (hub, session) = hub_with_chat("surge-prompt-entry");
    hub.session_log(&session).await;
    let now = now_ms();
    for (seq, at, kind) in [(1, now - 70_000, "turn_started"), (2, now - 10_000, "turn_result")] {
        session.time_breakdown.lock().unwrap().record(&EventRecord {
            seq,
            at,
            kind: kind.into(),
            dir: "mux".into(),
            msg: json!({"turnSeq":1,"turnId":"previous","status":"completed"}),
            host_seq: None,
        });
    }
    let options = || PromptOptions {
        prompt_id: Some("delivery-123".into()),
        class: Some(PromptClass::Fyi),
        agent: Some("reporter".into()),
        provenance: Some(crate::prompt_provenance::session_message(
            "reporter",
            "reporter",
            &session.id,
        )),
        ..Default::default()
    };
    let blocks = vec![json!({"type":"text","text":"org/app#123 runner report"})];
    assert!(
        hub.hold_surge_message(&session, "prior", "cli", &blocks, &options(), now - 1000)
            .unwrap()
            .is_none()
    );
    for resend in [false, true] {
        let (tx, accepted) = tokio::sync::oneshot::channel();
        let opts = PromptOptions {
            resend,
            on_accepted: Some(Box::new(move |v| {
                tx.send(v).unwrap();
            })),
            ..options()
        };
        let result = hub.prompt_with(&session, blocks.clone(), "cli", false, opts).await.unwrap();
        assert_eq!(result["_meta"]["acpmux"]["surgeHeld"], true);
        let receipt = accepted.await.unwrap();
        assert_eq!(receipt["surgeHeld"], true);
        assert_eq!(receipt["promptId"], "delivery-123");
        assert_eq!(receipt["threadId"], "topic:pr/org/app/123");
        // Make the retry consult the durable journal, as it must after daemon replacement.
        session.prompts.lock().unwrap().clear();
    }
    let events = hub.events(&session.id, 0, 1000).unwrap();
    assert_eq!(
        events.iter().filter(|e| e.kind == "inbox" && e.msg["surgeHeld"] == true).count(),
        1
    );
    assert!(!events.iter().any(|e| matches!(
        e.kind.as_str(),
        "user_message" | "_acpmux/message" | "turn_started" | "queued"
    )));

    // A daemon re-dispatch (queue resume, steer or composed inbox digest) is not a
    // second network arrival. Exercise the same internal entry the queue uses and
    // inspect its acceptance without waiting for a user to read the ordinary inbox.
    let (tx, mut accepted) = tokio::sync::oneshot::channel();
    let opts = PromptOptions {
        prompt_id: Some("already-admitted".into()),
        inbox: true,
        skip_surge_admission: true,
        on_accepted: Some(Box::new(move |v| {
            let _ = tx.send(v);
        })),
        ..options()
    };
    let dispatch = hub.run_prompt(&session, blocks, "cli", false, opts);
    tokio::pin!(dispatch);
    let receipt = tokio::select! {
        biased;
        receipt = &mut accepted => receipt.unwrap(),
        result = &mut dispatch => accepted.try_recv().unwrap_or_else(|_| panic!("no acceptance: {result:?}")),
        _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => panic!("no inbox acceptance"),
    };
    assert_eq!(receipt["promptId"], "already-admitted");
    assert_eq!(receipt["inbox"], true);
    assert_ne!(receipt["surgeHeld"], true);
}

#[tokio::test]
#[ignore = "requires an owner-exported coordinator trace"]
async fn coordinator_surge_flood_admission() {
    let path = std::env::var("ACPMUX_SURGE_TRACE").expect("path to the coordinator trace");
    let trace = serde_json::from_reader(std::fs::File::open(path).unwrap()).unwrap();
    replay(trace);
}
