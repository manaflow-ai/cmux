//! `conversation-inbox-op` once per `op_id` (`conversation-inbox-op-once-v1`): a phone's
//! resends after lost replies write once and publish one `conversation-inbox-changed`, and a
//! late resend of a pin after an unpin pins nothing. No `op_id` runs every time, as before.

use super::super::*;

const SEED: u64 = 7;

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

fn setup() -> (Arc<Mux>, u64, String) {
    let mux = Mux::new_for_test("inbox-op-once", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    let created = run(
        &mux,
        client,
        json!({"cmd":"conversation-create","idempotency_key":"create-1","actor":"user_local",
               "title":"mux","participants":[
                   {"id":"user_local","kind":"human","display_name":"Me"},
                   {"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux"}]}),
    )
    .unwrap();
    (mux, client, created["conversation"]["id"].as_str().unwrap().to_owned())
}

fn inbox_events(events: &crate::MuxEventReceiver) -> u64 {
    events
        .try_iter()
        .filter(|event| {
            matches!(event, MuxEvent::Conversation(change)
                if matches!(change.as_ref(), crate::conversation_store::ConversationEvent::Inbox { .. }))
        })
        .count() as u64
}

fn op(conversation: &str, op: Value, op_id: Option<&str>) -> Value {
    let mut request =
        json!({"cmd": "conversation-inbox-op", "conversation": conversation, "op": op});
    if let Some(id) = op_id {
        request["op_id"] = json!(id);
    }
    request
}

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
}

/// `ops` pins and mark-unreads, each resent until a reply arrives (half the replies lost):
/// the sends and the `conversation-inbox-changed` events they published.
fn retried(ops: usize, op_ids: bool) -> (u64, u64) {
    let (mux, client, conversation) = setup();
    let events = mux.subscribe();
    let mut rng = Lcg(SEED);
    let mut sends = 0;
    for i in 0..ops {
        let body = match i % 4 {
            0 => json!({"kind": "inbox.pin", "pinned": true}),
            1 => json!({"kind": "inbox.mark_unread", "unread": true}),
            2 => json!({"kind": "inbox.pin", "pinned": false}),
            _ => json!({"kind": "inbox.mark_unread", "unread": false}),
        };
        let id = format!("phone-op-{i}");
        loop {
            sends += 1;
            run(&mux, client, op(&conversation, body.clone(), op_ids.then_some(id.as_str())))
                .unwrap();
            if rng.next() % 100 >= 50 {
                break;
            }
        }
    }
    (sends, inbox_events(&events))
}

#[test]
fn retries_across_lost_replies_publish_one_change() {
    for (scale, ops) in [("1x", 20_usize), ("10x", 200)] {
        let (before_sends, before) = retried(ops, false);
        let (after_sends, after) = retried(ops, true);
        assert_eq!(before_sends, after_sends, "the seed loses the same replies");
        assert!(before_sends > ops as u64);
        for (when, sends, published) in
            [("before", before_sends, before), ("after", after_sends, after)]
        {
            for (metric, value) in
                [("list_ops", ops as u64), ("sends", sends), ("inbox_changed_events", published)]
            {
                println!(
                    "{when} NETCOND {}",
                    json!({"surface": "list", "profile": "reply-loss-50pct@seed7",
                           "phase": "warm", "scale": scale, "metric": metric, "value": value,
                           "run": 0, "seed": SEED})
                );
            }
        }
        assert_eq!(after, ops as u64, "one change per op, none per resend");
        assert!(before > after);
    }
}

#[test]
fn a_late_resend_of_a_pin_after_an_unpin_pins_nothing() {
    let (mux, client, conversation) = setup();
    let pin = json!({"kind": "inbox.pin", "pinned": true});
    let unpin = json!({"kind": "inbox.pin", "pinned": false});
    let first = run(&mux, client, op(&conversation, pin.clone(), Some("p1"))).unwrap();
    assert_eq!(first["pinned"], true);
    let unpinned = run(&mux, client, op(&conversation, unpin, Some("u1"))).unwrap();
    assert_eq!(unpinned["pinned"], false);
    let events = mux.subscribe();
    // The pin's resend arrives late: it answers the pin's first reply, and the state stays.
    let late = run(&mux, client, op(&conversation, pin.clone(), Some("p1"))).unwrap();
    assert_eq!(late, first);
    assert_eq!(inbox_events(&events), 0);
    let state = run(
        &mux,
        client,
        op(
            &conversation,
            json!({"kind": "inbox.mark_unread",
        "unread": false}),
            None,
        ),
    )
    .unwrap();
    assert_eq!(state["pinned"], false);
    // Without an id, the old behavior: the resend pins again.
    let again = run(&mux, client, op(&conversation, pin, None)).unwrap();
    assert_eq!(again["pinned"], true);
}

#[test]
fn an_op_id_reused_for_another_op_or_malformed_is_refused() {
    let (mux, client, conversation) = setup();
    let pin = json!({"kind": "inbox.pin", "pinned": true});
    run(&mux, client, op(&conversation, pin, Some("x"))).unwrap();
    let other = json!({"kind": "inbox.mark_unread", "unread": true});
    let error = run(&mux, client, op(&conversation, other.clone(), Some("x"))).unwrap_err();
    assert!(error.to_string().contains("op_id"), "{error}");
    let long = "x".repeat(crate::conversation_inbox_once::OP_ID_MOST + 1);
    for bad in ["", long.as_str()] {
        let error = run(&mux, client, op(&conversation, other.clone(), Some(bad))).unwrap_err();
        assert!(error.to_string().contains("op_id"), "{error}");
    }
    // The capability is advertised.
    let identity = run(&mux, client, json!({"cmd": "identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c == crate::conversation_inbox_once::CAPABILITY)
    );
}

#[test]
fn the_ids_kept_are_bounded() {
    let (mux, client, conversation) = setup();
    let most = crate::conversation_inbox_once::INBOX_OP_ONCE_MOST;
    for i in 0..most * 3 {
        let body = json!({"kind": "inbox.mark_unread", "unread": i % 2 == 0});
        run(&mux, client, op(&conversation, body.clone(), Some(&format!("op-{i}")))).unwrap();
        run(&mux, client, op(&conversation, body, Some(&format!("op-{i}")))).unwrap();
    }
    let (slots, order, repeats) = mux.inbox_ops_kept();
    assert_eq!(slots, most);
    assert!(order <= most * 4 + 1, "{order}");
    assert_eq!(repeats, (most * 3) as u64);
}
