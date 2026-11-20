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
    for a in trace.arrivals {
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
        "arrivals=378 senders=86 held={} immediate_path={} protected={}",
        held.len(),
        admitted.len(),
        trace.protected_ids.len()
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
#[ignore = "requires an owner-exported coordinator trace"]
async fn coordinator_surge_flood_admission() {
    let path = std::env::var("ACPMUX_SURGE_TRACE").expect("path to the coordinator trace");
    let trace = serde_json::from_reader(std::fs::File::open(path).unwrap()).unwrap();
    replay(trace);
}
