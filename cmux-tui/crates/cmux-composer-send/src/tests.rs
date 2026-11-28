use super::*;

fn key(params: &Value) -> &str {
    params["key"].as_str().unwrap()
}

#[test]
fn text_and_return_go_in_one_request() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let now = Instant::now();
    outbox.push("ls -la", true, now);
    let (_, params) = outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(params["text"], "ls -la");
    assert_eq!(params["paste"], true);
    assert_eq!(params["submit"], true);

    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    outbox.push("ls -la", true, now);
    let (_, params) = outbox.next_request(Form::TextReturn).unwrap();
    assert_eq!(params["text"], "ls -la\r");
    assert!(params.get("submit").is_none());
}

#[test]
fn a_lost_answer_goes_again_under_the_same_key() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let now = Instant::now();
    let seq = outbox.push("make", true, now);
    let (_, first) = outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(outbox.answer(seq, Answer::Lost), None);
    let (_, second) = outbox.next_request(Form::PasteSubmit).unwrap();
    outbox.link_lost();
    let (_, third) = outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(key(&first), key(&second));
    assert_eq!(key(&first), key(&third));
    assert_eq!(outbox.answer(seq, Answer::Applied), Some(Done { seq, outcome: Outcome::Sent }));
    assert!(outbox.is_empty());
}

#[test]
fn sends_pipeline_in_tap_order_up_to_the_window() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let now = Instant::now();
    let seqs: Vec<u64> =
        (0..MAX_IN_FLIGHT + 1).map(|i| outbox.push(format!("m{i}"), true, now)).collect();
    let sent: Vec<u64> =
        std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit).map(|(seq, _)| seq)).collect();
    assert_eq!(sent, seqs[..MAX_IN_FLIGHT], "in tap order, a window at a time");
    outbox.answer(seqs[0], Answer::Applied);
    let (next, params) = outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(next, seqs[MAX_IN_FLIGHT]);
    assert_eq!(key(&params), format!("phone-{next}"));
}

#[test]
fn a_lost_answer_sends_the_whole_pipeline_again_in_order_and_late_answers_still_settle() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let now = Instant::now();
    let a = outbox.push("a", true, now);
    let b = outbox.push("b", true, now);
    let first: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
    assert_eq!(outbox.answer(a, Answer::Lost), None);
    let again: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
    assert_eq!(first, again, "the same requests, same keys, same order");
    assert_eq!(outbox.answer(b, Answer::Applied), Some(Done { seq: b, outcome: Outcome::Sent }));
    assert_eq!(outbox.answer(a, Answer::Applied), Some(Done { seq: a, outcome: Outcome::Sent }));
    assert!(outbox.is_empty());
}

#[test]
fn past_the_hold_a_tried_send_may_have_been_sent_and_an_untried_one_was_not() {
    let mut outbox = Outbox::new("phone", Duration::from_secs(10));
    let now = Instant::now();
    let tried = outbox.push("tried", true, now);
    let untried = outbox.push("untried", true, now);
    outbox.next_request(Form::PasteSubmit);
    outbox.link_lost();
    assert!(outbox.expire(now + Duration::from_secs(9)).is_empty());
    let done = outbox.expire(now + Duration::from_secs(10));
    assert_eq!(
        done,
        vec![
            Done { seq: tried, outcome: Outcome::MaybeSent { text: "tried".into() } },
            Done { seq: untried, outcome: Outcome::NotSent { text: "untried".into() } },
        ]
    );
}

#[test]
fn an_uncertain_error_is_maybe_sent_and_never_resent() {
    let t0 = Instant::now();
    let mut outbox = Outbox::new("n", DEFAULT_HOLD);
    let seq = outbox.push("make deploy", true, t0);
    outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(
        outbox.answer(seq, Answer::Uncertain),
        Some(Done { seq, outcome: Outcome::MaybeSent { text: "make deploy".into() } })
    );
    assert!(outbox.next_request(Form::PasteSubmit).is_none());
}

#[test]
fn giving_up_says_which_sends_may_have_left() {
    let t0 = Instant::now();
    let mut outbox = Outbox::new("n", DEFAULT_HOLD);
    let tried = outbox.push("a", true, t0);
    let untried = outbox.push("b", true, t0);
    outbox.next_request(Form::PasteSubmit).unwrap();
    outbox.link_lost();
    assert_eq!(
        outbox.give_up(),
        vec![
            Done { seq: tried, outcome: Outcome::MaybeSent { text: "a".into() } },
            Done { seq: untried, outcome: Outcome::NotSent { text: "b".into() } },
        ]
    );
    assert!(outbox.is_empty());
}

#[test]
fn one_send_given_up_says_whether_it_may_have_left() {
    let t0 = Instant::now();
    let mut outbox = Outbox::new("n", DEFAULT_HOLD);
    let a = outbox.push("a", true, t0);
    let b = outbox.push("b", true, t0);
    outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(outbox.give_up_send(a), None, "in flight: its answer decides");
    assert_eq!(
        outbox.give_up_send(b),
        Some(Done { seq: b, outcome: Outcome::NotSent { text: "b".into() } })
    );
    outbox.answer(a, Answer::Lost);
    assert_eq!(
        outbox.give_up_send(a),
        Some(Done { seq: a, outcome: Outcome::MaybeSent { text: "a".into() } })
    );
    assert!(outbox.is_empty());
}

#[test]
fn typed_keys_go_as_bytes_under_a_key_in_order_with_composer_sends() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let now = Instant::now();
    let a = outbox.push_keys(b"\x1b[A".to_vec(), now);
    let b = outbox.push("ls", true, now);
    let c = outbox.push_keys(b"y".to_vec(), now);
    let sent: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::TextReturn)).collect();
    assert_eq!(sent.iter().map(|(s, _)| *s).collect::<Vec<_>>(), vec![a, b, c]);
    assert_eq!(sent[0].1["bytes"], STANDARD.encode(b"\x1b[A"));
    assert!(sent[0].1.get("text").is_none());
    assert_eq!(sent[1].1["text"], "ls\r");
    assert_eq!(sent[2].1["bytes"], STANDARD.encode(b"y"));
}

#[test]
fn keys_held_across_a_lost_link_go_again_in_order_under_the_same_keys_once_answered() {
    let mut outbox = Outbox::new("phone", Duration::from_secs(10));
    let now = Instant::now();
    let a = outbox.push_keys(b"a".to_vec(), now);
    let b = outbox.push_keys(b"b".to_vec(), now);
    let first: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
    outbox.link_lost();
    assert!(outbox.expire(now + Duration::from_secs(5)).is_empty());
    let again: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
    assert_eq!(first, again, "same bytes, same keys, same order: the daemon applies each once");
    assert_eq!(key(&again[0].1), format!("phone-{a}"));
    assert_eq!(outbox.answer(a, Answer::Applied), Some(Done { seq: a, outcome: Outcome::Sent }));
    assert_eq!(outbox.answer(b, Answer::Applied), Some(Done { seq: b, outcome: Outcome::Sent }));
    assert!(outbox.is_empty());
}

#[test]
fn keys_past_the_hold_are_not_sent_or_maybe_sent_never_dropped() {
    let mut outbox = Outbox::new("phone", Duration::from_secs(10));
    let now = Instant::now();
    let tried = outbox.push_keys(b"x".to_vec(), now);
    let untried = outbox.push_keys(b"z".to_vec(), now);
    outbox.next_request(Form::PasteSubmit);
    outbox.link_lost();
    assert_eq!(
        outbox.expire(now + Duration::from_secs(10)),
        vec![
            Done { seq: tried, outcome: Outcome::MaybeSent { text: "x".into() } },
            Done { seq: untried, outcome: Outcome::NotSent { text: "z".into() } },
        ]
    );
    assert!(outbox.is_empty());
}

#[test]
fn a_refused_key_is_not_sent_and_not_resent() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let seq = outbox.push_keys(b"y".to_vec(), Instant::now());
    outbox.next_request(Form::PasteSubmit);
    assert_eq!(
        outbox.answer(seq, Answer::Refused),
        Some(Done { seq, outcome: Outcome::NotSent { text: "y".into() } })
    );
    assert!(outbox.next_request(Form::PasteSubmit).is_none());
}

#[test]
fn a_refusal_gives_the_text_back() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let seq = outbox.push("y", true, Instant::now());
    outbox.next_request(Form::PasteSubmit);
    assert_eq!(
        outbox.answer(seq, Answer::Refused),
        Some(Done { seq, outcome: Outcome::NotSent { text: "y".into() } })
    );
}

#[test]
fn the_hold_stays_below_the_daemons_key_memory_and_keys_fit() {
    let outbox = Outbox::new("x".repeat(500), Duration::from_secs(3600));
    assert!(outbox.hold() < DAEMON_KEY_TTL);
    let mut outbox = outbox;
    outbox.push("t", true, Instant::now());
    let (_, params) = outbox.next_request(Form::PasteSubmit).unwrap();
    assert!(key(&params).len() <= MAX_KEY_LEN);
}

#[test]
fn a_daemon_without_keys_is_not_served() {
    assert_eq!(Form::from_caps(["send-expect-agent-v1"]), None);
    assert_eq!(Form::from_caps(["send-key-v1"]), Some(Form::TextReturn));
    assert_eq!(Form::from_caps(["send-key-v1", "send-expect-agent-v1"]), Some(Form::PasteSubmit));
    assert_eq!(
        Form::from_caps(["send-key-v1", "send-expect-agent-v1", "send-typed-submit-v1"]),
        Some(Form::TypedSubmit)
    );
}

/// A one-line draft for a full-screen program: typed text and its Return in one keyed
/// request, no `paste` (Leo, 2026-11-21: "the text goes through. But then the send doesn't
/// go through"). Pasted Sends keep the paste on the same daemon.
#[test]
fn a_typed_send_is_one_request_without_paste() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    let now = Instant::now();
    outbox.push_typed("/status", now);
    outbox.push("ls -la", true, now);
    let (_, typed) = outbox.next_request(Form::TypedSubmit).unwrap();
    assert_eq!(typed["text"], "/status");
    assert_eq!(typed["submit"], true);
    assert!(typed.get("paste").is_none());
    assert!(!key(&typed).is_empty());
    let (_, pasted) = outbox.next_request(Form::TypedSubmit).unwrap();
    assert_eq!(pasted["paste"], true);
    assert_eq!(pasted["submit"], true);
}

/// Attached after the tap to a daemon without `send-typed-submit-v1`: still one request,
/// as a paste with Return, never the text and a separate Return.
#[test]
fn a_typed_send_to_an_older_daemon_is_a_paste_with_submit() {
    let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
    outbox.push_typed("/status", Instant::now());
    let (_, params) = outbox.next_request(Form::PasteSubmit).unwrap();
    assert_eq!(params["text"], "/status");
    assert_eq!(params["paste"], true);
    assert_eq!(params["submit"], true);
}
