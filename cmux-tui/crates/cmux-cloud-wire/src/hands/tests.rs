use serde_json::json;

use super::tracker::{Change, Tracker};
use super::*;

const HAND: &str = "hand_abcdefghij234567klmn";
const ID: &str = "0f6c2a9e-1b2c-4d5e-8f90-123456789abc";
const ID2: &str = "1f6c2a9e-1b2c-4d5e-8f90-123456789abc";

#[test]
fn ids_check_like_the_server() {
    assert!(is_hand_id(HAND));
    assert!(!is_hand_id("hand_abcdefghij234567klm1"), "1 is not base32");
    assert!(!is_hand_id("hand_ABCDEFGHIJ234567KLMN"));
    assert!(!is_hand_id("hand_short"));
    assert!(is_approval_id(ID));
    assert!(!is_approval_id("0F6C2A9E-1B2C-4D5E-8F90-123456789ABC"));
    assert!(!is_approval_id("../../v1/hands"));
    assert!(is_nonce(&"a0".repeat(8)));
    assert!(!is_nonce("abc"));
    assert!(!is_nonce(&"g".repeat(16)));
    assert!(!is_nonce(&"a".repeat(129)));
}

#[test]
fn a_raise_loosens_the_hand() {
    use HandLevel::*;
    assert!(ReadOnly.is_raise(Ask));
    assert!(Ask.is_raise(Full));
    assert!(!Full.is_raise(Auto));
    assert!(!Auto.is_raise(Auto));
    assert_eq!(HandLevel::parse("read-only"), Some(ReadOnly));
    assert_eq!(serde_json::to_value(ReadOnly).unwrap(), json!("read-only"));
    assert_eq!(HandLevel::parse("root"), None);
}

#[test]
fn a_summary_reads_leniently() {
    let row = json!({"hand": HAND, "name": "Build box", "profile": "mac", "online": true, "level": "auto", "pending_approvals": 2});
    let s = HandSummary::from_value(&row).unwrap();
    assert_eq!(s.profile, Some(HandProfile::Mac));
    assert_eq!(s.level, Some(HandLevel::Auto));
    assert_eq!(s.pending_approvals, Some(2));
    let odd = HandSummary::from_value(
        &json!({"hand": HAND, "online": "yes", "level": "root", "profile": 3}),
    )
    .unwrap();
    assert_eq!((odd.online, odd.level, odd.profile, odd.name.as_str()), (false, None, None, ""));
    assert_eq!(odd.display_name(), HAND);
    assert!(odd.may_wait(), "an unknown count asks");
    assert!(
        HandSummary::list(&json!([{"name": "x"}])).is_none(),
        "a row without its id fails the list"
    );
    assert!(HandSummary::list(&json!({})).is_none());
}

#[test]
fn a_summary_line_names_the_action_and_its_detail() {
    assert_eq!(
        describe(Some(&json!({"action": "exec", "argv": ["git", "push", 1]}))),
        "exec: git push 1"
    );
    assert_eq!(describe(Some(&json!({"action": "write", "paths": ["/a", "/b"]}))), "write: /a, /b");
    assert_eq!(
        describe(Some(&json!({"action": "open", "title": "Docs", "paths": ["/a"]}))),
        "open: Docs"
    );
    assert_eq!(describe(Some(&json!({"prompt": "go"}))), "go");
    assert_eq!(describe(Some(&json!("plain"))), "plain");
    assert_eq!(describe(None), "");
    assert_eq!(describe(Some(&json!("é".repeat(400)))).chars().count(), 300);
}

#[test]
fn an_approval_parses_with_checked_ids_only() {
    let a =
        HandApproval::from_value(&json!({"id": ID, "summary": "x", "at": 1000}), Some(HAND), 5.0)
            .unwrap();
    assert_eq!(a.hand, HAND);
    assert_eq!(a.at, 1000.0);
    assert_eq!(a.key, format!("hand-approval.{HAND}.{ID}"));
    let late = HandApproval::from_value(&json!({"hand": HAND, "id": ID}), None, 5.0).unwrap();
    assert_eq!(late.at, 5.0, "no `at`: now");
    assert!(HandApproval::from_value(&json!({"hand": "hand_x", "id": ID}), None, 0.0).is_none());
    assert!(HandApproval::from_value(&json!({"hand": HAND, "id": "1"}), None, 0.0).is_none());
    let list = HandApproval::list(&json!([{"id": ID}, {"id": "bad"}, 7]), HAND, 0.0);
    assert_eq!(list.len(), 1);
}

#[test]
fn frames_decode_to_what_the_hands_need() {
    assert_eq!(HandFrame::decode(br#"{"t":"welcome","v":1}"#, 0.0), HandFrame::Welcome);
    assert_eq!(
        HandFrame::decode(br#"{"t":"snapshot","state":{"big":[1,2,3]}}"#, 0.0),
        HandFrame::Snapshot
    );
    let pending = format!(
        r#"{{"t":"hand-approval-pending","hand":"{HAND}","id":"{ID}","summary":{{"action":"exec","argv":["ls"]}},"at":9,"sign":"x"}}"#
    );
    match HandFrame::decode(pending.as_bytes(), 0.0) {
        HandFrame::Pending(a) => assert_eq!((a.summary.as_str(), a.at), ("exec: ls", 9.0)),
        other => panic!("{other:?}"),
    }
    let settled = format!(
        r#"{{"t":"hand-approval-settled","hand":"{HAND}","id":"{ID}","outcome":"denied"}}"#
    );
    assert_eq!(
        HandFrame::decode(settled.as_bytes(), 0.0),
        HandFrame::Settled { hand: HAND.into(), id: ID.into(), outcome: HandOutcome::Denied }
    );
    let unknown =
        format!(r#"{{"t":"hand-approval-settled","hand":"{HAND}","id":"{ID}","outcome":"maybe"}}"#);
    assert_eq!(HandFrame::decode(unknown.as_bytes(), 0.0), HandFrame::Ignored);
    assert_eq!(HandFrame::decode(br#"{"t":"event"}"#, 0.0), HandFrame::Ignored);
    assert_eq!(HandFrame::decode(b"not json", 0.0), HandFrame::Ignored);
    assert_eq!(HandFrame::decode(b"[1]", 0.0), HandFrame::Ignored);
}

#[test]
fn the_socket_url_is_the_user_path_on_the_api_origin() {
    assert_eq!(user_socket_url("https://api.cmux.dev"), "wss://api.cmux.dev/v1/wire/user");
    assert_eq!(user_socket_url("http://127.0.0.1:8787/"), "ws://127.0.0.1:8787/v1/wire/user");
}

#[test]
fn reconnects_back_off_to_thirty_seconds() {
    assert_eq!(reconnect_delay_ms(0, 0.5), 500);
    assert_eq!(reconnect_delay_ms(1, 0.5), 1000);
    assert_eq!(reconnect_delay_ms(20, 0.5), 30_000);
    assert_eq!(reconnect_delay_ms(0, 0.0), 400);
    assert_eq!(reconnect_delay_ms(0, 1.0), 600);
}

#[test]
fn targets_name_a_hand_or_a_profile_default() {
    let hand = Target::parse(HAND).unwrap();
    assert_eq!(hand.challenge_path(), format!("/v1/hands/{HAND}/level-challenge"));
    assert_eq!(hand.level_path(), format!("/v1/hands/{HAND}/level"));
    let mac = Target::parse("default:mac").unwrap();
    assert_eq!(mac.challenge_path(), "/v1/hands/defaults/mac/challenge");
    assert_eq!(mac.level_path(), "/v1/hands/defaults/mac");
    assert_eq!(mac.text(), "default:mac");
    assert!(Target::parse("default:linux").is_none());
    assert!(Target::parse("../x").is_none());
}

#[test]
fn a_lower_is_plain_and_a_raise_takes_the_proof() {
    let hand = Target::Hand(HAND.into());
    assert_eq!(level_plan(&hand, Some(HandLevel::Full), HandLevel::Ask), LevelPlan::Plain);
    assert_eq!(level_plan(&hand, Some(HandLevel::Ask), HandLevel::Ask), LevelPlan::Plain);
    assert_eq!(level_plan(&hand, Some(HandLevel::Ask), HandLevel::Full), LevelPlan::Proof);
    assert_eq!(level_plan(&hand, None, HandLevel::ReadOnly), LevelPlan::Proof);
    assert_eq!(
        level_plan(&Target::Default(HandProfile::Sandbox), None, HandLevel::Full),
        LevelPlan::Plain
    );
}

#[test]
fn proof_texts_are_the_servers() {
    assert_eq!(
        proof::presence_registration("prod", "ins_1", "X", "Y"),
        "cmux-hand-presence-key:prod:ins_1:X:Y"
    );
    assert_eq!(
        proof::level("prod", &Target::Default(HandProfile::Mac), HandLevel::ReadOnly, "ab"),
        "cmux-hand-level:prod:default:mac:read-only:ab"
    );
    assert_eq!(
        proof::approval("dev", HAND, ID),
        format!("cmux-hand-approval:dev:{HAND}:{ID}:allow")
    );
}

fn approval(id: &str) -> HandApproval {
    HandApproval::from_value(&json!({"hand": HAND, "id": id, "at": 1}), None, 0.0).unwrap()
}

#[test]
fn a_request_posts_once_with_its_hands_name() {
    let mut t = Tracker::default();
    t.set_hands(vec![HandSummary::from_value(&json!({"hand": HAND, "name": "Box"})).unwrap()]);
    match t.add(approval(ID), 1) {
        Some(Change::Pending { name, .. }) => assert_eq!(name, "Box"),
        other => panic!("{other:?}"),
    }
    assert!(t.add(approval(ID), 2).is_none());
}

#[test]
fn a_read_never_drops_a_request_that_arrived_during_it() {
    let mut t = Tracker::default();
    t.add(approval(ID), 10);
    t.add(approval(ID2), 30);
    // The read began at 20 and lists neither: the first ended while away, the second arrived after.
    let changes = t.refreshed(20, vec![], 40);
    assert_eq!(changes.len(), 1);
    assert!(
        matches!(&changes[0], Change::Settled { approval, outcome: None } if approval.id == ID)
    );
    assert!(t.approval(&approval(ID2).key).is_some());
}

#[test]
fn a_read_that_started_earlier_never_posts_an_ended_request_again() {
    let mut t = Tracker::default();
    t.add(approval(ID), 10);
    let key = approval(ID).key;
    assert!(matches!(
        t.settle(&key, Some(HandOutcome::Allowed), 15),
        Some(Change::Settled { outcome: Some(HandOutcome::Allowed), .. })
    ));
    assert!(t.refreshed(5, vec![approval(ID)], 20).is_empty());
    // Ten minutes on, the key is forgotten.
    t.refreshed(30, vec![], 15 + tracker::ENDED_KEEP_MS);
    assert_eq!(t.refreshed(30, vec![approval(ID)], 16 + tracker::ENDED_KEEP_MS).len(), 1);
}

#[test]
fn settling_an_unknown_request_still_remembers_it() {
    let mut t = Tracker::default();
    assert!(t.settle(&approval(ID).key, None, 1).is_none());
    assert!(t.refreshed(0, vec![approval(ID)], 2).is_empty());
}

#[test]
fn stopping_settles_every_request_and_drops_the_hands() {
    let mut t = Tracker::default();
    t.set_hands(vec![HandSummary::from_value(&json!({"hand": HAND})).unwrap()]);
    t.add(approval(ID), 1);
    t.add(approval(ID2), 1);
    assert_eq!(t.clear().len(), 2);
    assert!(t.hands().is_empty() && t.pending().is_empty());
}

#[test]
fn a_read_that_failed_part_way_adds_what_it_got_and_drops_nothing() {
    let mut t = Tracker::default();
    t.add(approval(ID2), 1);
    t.settle(&approval("2f6c2a9e-1b2c-4d5e-8f90-123456789abc").key, None, 2);
    let changes =
        t.partly_read(vec![approval(ID), approval("2f6c2a9e-1b2c-4d5e-8f90-123456789abc")], 3);
    assert_eq!(changes.len(), 1, "only the new request, never an ended one: {changes:?}");
    assert!(t.approval(&approval(ID).key).is_some());
    assert!(t.approval(&approval(ID2).key).is_some(), "the unread hand's request stays");
}
