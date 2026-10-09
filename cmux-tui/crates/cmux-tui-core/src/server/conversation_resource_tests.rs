//! The local conversation owner on `cmux.protocol/2`: reads scoped to the
//! caller's principal, send with key replay and conflict, typing and drafts
//! for the caller itself, and the `conversation.events` stream (snapshot,
//! live items, cursor resume, refusals, gap).

use super::super::*;
use super::events::{Step, step};
use crate::conversation_store::ConversationEvent;

struct Conn {
    id: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

fn conn(mux: &Arc<Mux>) -> Conn {
    let (writer, outbound) = tests::captured_writer();
    let id = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    Conn { id, writer, outbound }
}

fn raw(mux: &Arc<Mux>, conn: &Conn, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    handle_command(mux, conn.id, command, &conn.writer).unwrap()
}

/// Sends one v2 request and returns its response line.
fn v2(mux: &Arc<Mux>, conn: &Conn, operation: &str, mut params: Value, key: Option<&str>) -> Value {
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"r",
                              "operation":operation,"params":params});
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let line = envelope.to_string();
    let parsed = crate::resource_router::parse_resource_line(&line).expect("a v2 line");
    assert!(origin_gate::handle_resource_line(mux, conn.id, &line, parsed, &conn.writer));
    loop {
        let line: Value = serde_json::from_str(&next_line(conn)).unwrap();
        if line["type"] == "response" {
            return line;
        }
    }
}

fn next_line(conn: &Conn) -> String {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(line) = conn.outbound.try_pop() {
            return line;
        }
        assert!(Instant::now() < deadline, "no line within 5 s");
        std::thread::yield_now();
    }
}

/// The next stream item (or end) line.
fn stream_line(conn: &Conn) -> Value {
    loop {
        let line: Value = serde_json::from_str(&next_line(conn)).unwrap();
        if line["type"] == "stream_item" || line["type"] == "stream_end" {
            return line;
        }
    }
}

fn ok(response: &Value) -> Value {
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn error(response: &Value) -> (String, String) {
    assert_eq!(response["ok"], false, "{response}");
    let error = &response["error"];
    let reason = error["details"]["reason"].as_str().unwrap_or_default().to_owned();
    (error["code"].as_str().unwrap().to_owned(), reason)
}

fn create(mux: &Arc<Mux>, user: &Conn, key: &str, agent: &str) -> String {
    let created = raw(
        mux,
        user,
        json!({"cmd":"conversation-create","idempotency_key":key,"actor":"user_local","title":"t",
               "participants":[{"id":"user_local","kind":"human","display_name":"Me"},
                               {"id":agent,"kind":"agent","display_name":agent,"agent_class":"mux"}]}),
    );
    created["conversation"]["id"].as_str().unwrap().to_owned()
}

fn bound(mux: &Arc<Mux>, user: &Conn, participant: &str) -> Conn {
    let token = raw(mux, user, json!({"cmd":"conversation-agent-token","participant":participant}))
        ["token"]
        .clone();
    let agent = conn(mux);
    raw(mux, &agent, json!({"cmd":"conversation-bind","participant":participant,"token":token}));
    agent
}

fn send(mux: &Arc<Mux>, conn: &Conn, conversation: &str, key: &str, text: &str) -> Value {
    v2(mux, conn, "conversation.send", json!({"conversation":conversation,"text":text}), Some(key))
}

fn setup(name: &str) -> (Arc<Mux>, Conn, String, String) {
    let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
    let user = conn(&mux);
    let mine = create(&mux, &user, "c-mine", "agent_mux");
    let other = create(&mux, &user, "c-other", "agent_other");
    (mux, user, mine, other)
}

#[test]
fn reads_name_only_the_callers_conversations() {
    let (mux, user, mine, other) = setup("conv-v2-scope");
    ok(&send(&mux, &user, &mine, "k1", "hello mine"));
    ok(&send(&mux, &user, &other, "k2", "hello other"));
    let chief = bound(&mux, &user, "agent_mux");

    let listed = ok(&v2(&mux, &chief, "conversation.list", json!({}), None));
    let ids: Vec<&str> =
        listed.as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, vec![mine.as_str()]);
    assert_eq!(
        ok(&v2(&mux, &user, "conversation.list", json!({}), None)).as_array().unwrap().len(),
        2
    );

    let page =
        ok(&v2(&mux, &chief, "conversation.get", json!({"conversation":mine,"tail":5}), None));
    assert_eq!(page["messages"][0]["parts"][0]["text"], "hello mine");
    for (operation, params) in [
        ("conversation.get", json!({"conversation":other})),
        ("conversation.history", json!({"conversation":other,"before_seq":5,"limit":5})),
    ] {
        let refused = error(&v2(&mux, &chief, operation, params, None));
        assert_eq!(refused, ("operation.failed".into(), "not_participant".into()), "{operation}");
    }
    // Search sees only the principal's conversations; the user sees both.
    let hits = ok(&v2(&mux, &chief, "conversation.search", json!({"query":"hello"}), None));
    let hit_ids: Vec<&str> =
        hits.as_array().unwrap().iter().map(|h| h["conversation"].as_str().unwrap()).collect();
    assert_eq!(hit_ids, vec![mine.as_str()]);
    let all = ok(&v2(&mux, &user, "conversation.search", json!({"query":"hello"}), None));
    assert_eq!(all.as_array().unwrap().len(), 2);

    let missing = error(&v2(
        &mux,
        &user,
        "conversation.get",
        json!({"conversation":"conv_00000000000000000000000000"}),
        None,
    ));
    assert_eq!(missing.0, "resource.not_found");
}

#[test]
fn send_replays_by_key_and_refuses_a_reused_key_or_a_bad_one() {
    let (mux, user, mine, _) = setup("conv-v2-send");
    let first = ok(&send(&mux, &user, &mine, "cli-1", "hi"));
    assert_eq!(first["replayed"], false);
    assert_eq!(first["generation"], mine.as_str());
    let message = first["value"]["message"].clone();
    assert_eq!(message["author"], "user_local");
    assert_eq!(message["client_msg_id"], "cli-1");
    let again = ok(&send(&mux, &user, &mine, "cli-1", "hi"));
    assert_eq!(again["replayed"], true);
    assert_eq!(again["value"]["message"]["id"], message["id"]);
    assert_eq!(error(&send(&mux, &user, &mine, "cli-1", "other text")).0, "idempotency.conflict");
    assert_eq!(error(&send(&mux, &user, &mine, "has space", "x")).0, "validation.invalid");
    let both = v2(
        &mux,
        &user,
        "conversation.send",
        json!({"conversation":mine,"text":"a","parts":[{"type":"text","text":"b"}]}),
        Some("cli-2"),
    );
    assert_eq!(error(&both).0, "validation.invalid");
}

#[test]
fn typing_and_drafts_are_for_the_caller_itself() {
    let (mux, user, mine, _) = setup("conv-v2-drafts");
    let chief = bound(&mux, &user, "agent_mux");
    let stranger = bound(&mux, &user, "agent_other");
    let typing = |conn: &Conn, key: &str| {
        v2(&mux, conn, "conversation.typing", json!({"conversation":mine,"on":true}), Some(key))
    };
    assert_eq!(
        error(&typing(&stranger, "t1")),
        ("operation.failed".into(), "not_participant".into())
    );
    assert_eq!(ok(&typing(&chief, "t2"))["value"]["published"], true);

    let draft = |conn: &Conn, seq: u64, text: &str, fresh: bool| {
        v2(
            &mux,
            conn,
            "conversation.draft",
            json!({"conversation":mine,"turn":"turn:optchat:1","segment":0,"seq":seq,"kind":"talk",
                  "text":text,"fresh":fresh,"done":false}),
            Some(&format!("draft:{seq}")),
        )
    };
    assert_eq!(error(&draft(&user, 1, "x", true)), ("operation.failed".into(), "not_agent".into()));
    assert_eq!(error(&draft(&stranger, 1, "x", true)).1, "not_participant");
    assert_eq!(ok(&draft(&chief, 1, "Hel", true))["value"]["published"], true);
    let replay = ok(&draft(&chief, 1, "Hel", true));
    assert_eq!(
        (replay["value"]["published"].clone(), replay["replayed"].clone()),
        (json!(false), json!(true))
    );
    assert_eq!(error(&draft(&chief, 2, &"x".repeat(16 * 1024 + 1), false)).1, "text_too_large");
    let mut limited = false;
    for seq in 2..=12 {
        let response = draft(&chief, seq, "y", false);
        if response["ok"] == false {
            assert_eq!(error(&response).1, "rate_limited");
            limited = true;
        }
    }
    assert!(limited, "eleven drafts at once pass the 10/s burst");
}

#[test]
fn events_stream_a_snapshot_then_commits_typing_and_drafts_in_order() {
    let (mux, user, mine, other) = setup("conv-v2-events");
    ok(&send(&mux, &user, &mine, "k1", "before"));
    let chief = bound(&mux, &user, "agent_mux");
    let watcher = conn(&mux);
    let opened = ok(&v2(
        &mux,
        &watcher,
        "conversation.events",
        json!({"conversation":mine,"stream_id":"stream_11111111111111111111111111111111","tail":10}),
        None,
    ));
    let rev: u64 = opened["cursor"]["revision"].as_str().unwrap().parse().unwrap();
    assert_eq!(opened["cursor"]["generation"], mine.as_str());
    let snapshot = stream_line(&watcher);
    assert_eq!(snapshot["item"]["type"], "snapshot");
    assert_eq!(snapshot["item"]["reset_reason"], "initial");
    assert_eq!(snapshot["item"]["messages"][0]["parts"][0]["text"], "before");

    ok(&send(&mux, &user, &other, "k-other", "elsewhere"));
    ok(&send(&mux, &user, &mine, "k2", "after"));
    let message = stream_line(&watcher);
    assert_eq!(
        message["item"]["type"], "message",
        "another conversation's commit is not delivered"
    );
    assert_eq!(message["item"]["rev"], rev + 1);
    assert_eq!(message["cursor"]["revision"], (rev + 1).to_string());
    ok(&v2(&mux, &chief, "conversation.typing", json!({"conversation":mine,"on":true}), Some("t")));
    assert_eq!(stream_line(&watcher)["item"]["type"], "typing");
    ok(&v2(
        &mux,
        &chief,
        "conversation.draft",
        json!({"conversation":mine,"turn":"turn:optchat:2","segment":0,"seq":1,"kind":"talk",
               "text":"Wor","fresh":true,"done":false,"harness":"claude"}),
        Some("d1"),
    ));
    let draft = stream_line(&watcher)["item"].clone();
    assert_eq!(draft["type"], "draft");
    assert_eq!(draft["participant"], "agent_mux");
    assert_eq!(draft["text"], "Wor");
    assert_eq!(draft["harness"], "claude");
}

#[test]
fn events_resume_from_a_cursor_and_refuse_a_foreign_or_future_one() {
    let (mux, user, mine, other) = setup("conv-v2-cursor");
    let watcher = conn(&mux);
    let open = |stream: &str, cursor: Value| {
        v2(
            &mux,
            &watcher,
            "conversation.events",
            json!({"conversation":mine,"stream_id":stream,"cursor":cursor}),
            None,
        )
    };
    let head = ok(&v2(&mux, &user, "conversation.get", json!({"conversation":mine}), None))["conversation"]["rev"]
        .as_u64()
        .unwrap();
    let foreign =
        open("stream_22222222222222222222222222222222", json!({"generation":other,"revision":"1"}));
    assert_eq!(error(&foreign).0, "cursor.invalid");
    let ahead = open(
        "stream_33333333333333333333333333333333",
        json!({"generation":mine,"revision":(head + 5).to_string()}),
    );
    assert_eq!(error(&ahead).0, "cursor.invalid");

    // At the head: no snapshot, the next item is the next commit.
    ok(&open(
        "stream_44444444444444444444444444444444",
        json!({"generation":mine,"revision":head.to_string()}),
    ));
    ok(&send(&mux, &user, &mine, "k1", "live"));
    assert_eq!(stream_line(&watcher)["item"]["type"], "message");

    // Behind the head: a snapshot says the cursor expired.
    let other_watcher = conn(&mux);
    ok(&v2(
        &mux,
        &other_watcher,
        "conversation.events",
        json!({"conversation":mine,"stream_id":"stream_55555555555555555555555555555555",
               "cursor":{"generation":mine,"revision":head.to_string()}}),
        None,
    ));
    assert_eq!(stream_line(&other_watcher)["item"]["reset_reason"], "cursor_expired");
}

#[test]
fn a_missed_rev_ends_the_stream_with_a_gap() {
    let changed = |rev: u64| ConversationEvent::Changed {
        conversation: "conv_a".into(),
        rev,
        transaction: None,
        change: json!({"kind":"read-cursor","participant":"user_local","seq":1}),
    };
    let mut rev = 4;
    assert_eq!(step("conv_a", &mut rev, &changed(4)), Step::Skip, "already in the snapshot");
    assert!(matches!(step("conv_a", &mut rev, &changed(5)), Step::Item(_)));
    assert_eq!(rev, 5);
    assert_eq!(step("conv_a", &mut rev, &changed(7)), Step::Gap);
    let other = ConversationEvent::Typing {
        conversation: "conv_b".into(),
        participant: "x".into(),
        on: true,
    };
    assert_eq!(step("conv_a", &mut rev, &other), Step::Skip);
}

#[test]
fn the_remote_relay_admits_none_of_the_conversation_operations() {
    for operation in [
        "conversation.list",
        "conversation.get",
        "conversation.history",
        "conversation.search",
        "conversation.send",
        "conversation.typing",
        "conversation.draft",
        "conversation.events",
    ] {
        let frame = json!({"protocol":"cmux.protocol/2","type":"request","id":"r","operation":operation,
                           "params":{"machine":"current","session":"current"}});
        assert_eq!(
            remote_relay::gate::check_frame(&frame.to_string()),
            Err(remote_relay::gate::Denial::ResourceProtocol),
            "{operation}"
        );
    }
}

#[test]
fn drafts_never_reach_the_raw_subscribe_stream() {
    let draft = ConversationEvent::Draft {
        conversation: "c".into(),
        participant: "agent_mux".into(),
        item: json!({}),
    };
    assert!(draft.is_draft());
    let typing =
        ConversationEvent::Typing { conversation: "c".into(), participant: "p".into(), on: true };
    assert!(!typing.is_draft());
}

#[test]
fn a_connection_whose_agent_token_was_replaced_is_nobody_not_the_person() {
    let (mux, user, mine, _) = setup("conv-v2-rebind");
    let chief = bound(&mux, &user, "agent_mux");
    // The person mints a new token: the old binding ends.
    raw(&mux, &user, json!({"cmd":"conversation-agent-token","participant":"agent_mux"}));
    assert_ne!(mux.conversation_principal(chief.id), "user_local");
    let refused = send(&mux, &chief, &mine, "k-after", "as the person?");
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(
        ok(&v2(&mux, &chief, "conversation.list", json!({}), None)).as_array().unwrap().is_empty()
    );
}

#[test]
fn an_events_stream_ends_when_its_principal_loses_the_conversation() {
    let (mux, user, mine, _) = setup("conv-v2-revoke");
    let chief = bound(&mux, &user, "agent_mux");
    ok(&v2(
        &mux,
        &chief,
        "conversation.events",
        json!({"conversation":mine,"stream_id":"stream_66666666666666666666666666666666","tail":0}),
        None,
    ));
    assert_eq!(stream_line(&chief)["item"]["type"], "snapshot");
    raw(&mux, &user, json!({"cmd":"conversation-agent-token","participant":"agent_mux"}));
    ok(&send(&mux, &user, &mine, "k1", "private after the token changed"));
    let next = stream_line(&chief);
    assert_eq!(next["type"], "stream_end", "{next}");
}

#[test]
fn another_agent_cannot_use_up_a_turns_draft_seqs() {
    let (mux, user, mine, _) = setup("conv-v2-draft-owner");
    raw(
        &mux,
        &user,
        json!({"cmd":"conversation-op","conversation":mine,"idempotency_key":"add",
        "op":{"kind":"participants.add","participant":{"id":"agent_two","kind":"agent","display_name":"two"}}}),
    );
    let chief = bound(&mux, &user, "agent_mux");
    let two = bound(&mux, &user, "agent_two");
    let draft = |conn: &Conn, key: &str| {
        v2(
            &mux,
            conn,
            "conversation.draft",
            json!({"conversation":mine,"turn":"turn:optchat:9","segment":0,"seq":1,"kind":"talk",
                  "text":"x","fresh":true,"done":false}),
            Some(key),
        )
    };
    assert_eq!(ok(&draft(&two, "a"))["value"]["published"], true);
    assert_eq!(ok(&draft(&chief, "b"))["value"]["published"], true, "the Chief's seq 1 is its own");
}
