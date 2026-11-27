//! Parity with Swift's `Tests/CmuxNextMobileHostTests`: MobileHostPhoneCredentialsTests,
//! IPhonePairingSeedTests and IPhoneDevAutoApproveTests, case for case.

use cmux_mobile_host_core::credentials::{Credentials, Kind, Request};
use cmux_mobile_host_core::dev_auto_approve::{
    APPROVE_FIRST_KEY, approves, asks_quietly, auto_approve_tag, dev_tag,
};
use cmux_mobile_host_core::pairing_seed::{SeedRequest, trusts};
use cmux_mobile_host_core::record_name::acpmux_record_name;
use cmux_mobile_host_core::respond;
use serde_json::{Value, json};
use std::collections::BTreeSet;

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

fn issued(record: &str) -> Value {
    json!({"result": {"deviceId": record, "token": format!("tok-{record}")}})
}

fn listing(devices: Vec<Value>) -> Value {
    json!({"result": {"devices": devices}})
}

fn device(id: &str, name: &str) -> Value {
    device_as(id, name, "phone", false)
}

fn device_as(id: &str, name: &str, role: &str, revoked: bool) -> Value {
    json!({"id": id, "name": name, "role": role,
        "revoked_at": if revoked { json!("2026-10-25T00:00:00Z") } else { Value::Null }})
}

fn revoked() -> Value {
    json!({"result": {"revoked": true}})
}

fn kinds(requests: &[Request]) -> Vec<Kind> {
    requests.iter().map(|request| request.kind.clone()).collect()
}

fn issue(phone: &str) -> Kind {
    Kind::Issue { phone: phone.to_owned() }
}

fn revoke(record: &str) -> Kind {
    Kind::Revoke { record: record.to_owned() }
}

/// Connects with `listed` paired and listed, answers the first list with no records, returns what goes next.
fn connected(credentials: &mut Credentials, ids: &mut i64, listed: &[&str]) -> Vec<Request> {
    credentials.update(set(listed), Some(set(listed)), ids);
    let list = credentials.connected(ids)[0].clone();
    credentials.reply(list.id, &listing(vec![]), ids).unwrap()
}

#[test]
fn before_the_accounts_list_nothing_is_issued_or_revoked_for_being_unlisted() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    assert!(credentials.update(set(&["P1"]), None, &mut ids).is_empty());
    let records = vec![
        device("dv_p1", "phone-p1"),
        device("dv_gone", "phone-gone"),
        device_as("dv_old", "phone-old", "phone", true),
        device_as("dv_mac", "phone-mac", "client", false),
    ];
    let first = credentials.connected(&mut ids)[0].clone();
    assert_eq!(first.kind, Kind::List);
    assert_eq!(
        credentials.reply(first.id, &listing(records.clone()), &mut ids),
        Some(vec![]),
        "unread: nothing goes"
    );
    assert!(credentials.tokens().is_empty());

    let relist = credentials.update(set(&["P1"]), Some(set(&["P1"])), &mut ids)[0].clone();
    assert_eq!(relist.kind, Kind::List, "the account's list read: the records are listed again");
    let next = credentials.reply(relist.id, &listing(records), &mut ids).unwrap();
    assert_eq!(kinds(&next), vec![revoke("dv_gone"), issue("P1")]);
    assert_eq!(next[1].params(), json!({"name": "phone-p1", "role": "phone"}));
    assert_eq!(next[1].method(), "_acpmux/pair_issue");
    let confirm = credentials.reply(next[0].id, &revoked(), &mut ids).unwrap()[0].clone();
    assert_eq!(confirm.kind, Kind::List, "a list confirms the unlisted record is gone");
    assert_eq!(credentials.reply(next[1].id, &issued("dv_p1b"), &mut ids), Some(vec![]));
    assert_eq!(
        credentials.reply(confirm.id, &listing(vec![device("dv_p1b", "phone-p1")]), &mut ids),
        Some(vec![])
    );
    assert_eq!(credentials.tokens(), [("P1".to_owned(), "tok-dv_p1b".to_owned())].into());
    assert!(credentials.ending.is_empty());
    assert!(!credentials.refused);
}

#[test]
fn a_phone_paired_again_gets_a_new_credential_only_after_its_old_record_ends() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    let connection = connected(&mut credentials, &mut ids, &["P1"]);
    assert_eq!(credentials.reply(connection[0].id, &issued("dv_p1"), &mut ids), Some(vec![]));
    assert_eq!(
        kinds(&credentials.update(set(&[]), Some(set(&[])), &mut ids)),
        vec![revoke("dv_p1")]
    );
    assert!(credentials.tokens().is_empty(), "hostd drops it at once");
    credentials.disconnected();
    assert!(
        credentials.update(set(&["P1"]), Some(set(&["P1"])), &mut ids).is_empty(),
        "paired again, offline"
    );
    assert!(credentials.needs_connection());

    let list = credentials.connected(&mut ids)[0].clone();
    let connection =
        credentials.reply(list.id, &listing(vec![device("dv_p1", "phone-p1")]), &mut ids).unwrap();
    assert_eq!(kinds(&connection), vec![revoke("dv_p1")], "no issue before the old record ends");
    let relist = credentials.reply(connection[0].id, &revoked(), &mut ids).unwrap()[0].clone();
    assert_eq!(relist.kind, Kind::List);
    let again = credentials.reply(relist.id, &listing(vec![]), &mut ids).unwrap();
    assert_eq!(kinds(&again), vec![issue("P1")]);
    assert!(credentials.ending.is_empty());
}

#[test]
fn an_issue_whose_reply_was_lost_is_found_and_revoked_by_the_next_list() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    connected(&mut credentials, &mut ids, &["P1"]);
    assert!(
        credentials.update(set(&[]), Some(set(&[])), &mut ids).is_empty(),
        "no record id known yet"
    );
    credentials.disconnected();
    assert!(credentials.needs_connection(), "a removed phone's record may still be live");

    let list = credentials.connected(&mut ids)[0].clone();
    let revoke_new =
        credentials.reply(list.id, &listing(vec![device("dv_new", "phone-p1")]), &mut ids).unwrap();
    assert_eq!(kinds(&revoke_new), vec![revoke("dv_new")]);
    let relist = credentials.reply(revoke_new[0].id, &revoked(), &mut ids).unwrap()[0].clone();
    assert_eq!(credentials.reply(relist.id, &listing(vec![]), &mut ids), Some(vec![]));
    assert!(credentials.ending.is_empty());
    assert!(!credentials.needs_connection());
}

#[test]
fn a_refused_revocation_is_retried_on_a_new_connection() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    let first = connected(&mut credentials, &mut ids, &["P1"])[0].clone();
    assert_eq!(credentials.reply(first.id, &issued("dv_p1"), &mut ids), Some(vec![]));
    let refused = credentials.update(set(&["P1"]), Some(set(&[])), &mut ids)[0].clone();
    assert_eq!(refused.kind, revoke("dv_p1"));
    credentials.reply(refused.id, &json!({"error": {"message": "store write failed"}}), &mut ids);
    assert!(credentials.refused);
    assert!(credentials.needs_connection());

    credentials.disconnected();
    let list = credentials.connected(&mut ids)[0].clone();
    let again =
        credentials.reply(list.id, &listing(vec![device("dv_p1", "phone-p1")]), &mut ids).unwrap();
    assert_eq!(kinds(&again), vec![revoke("dv_p1")]);
    assert!(!credentials.refused, "the list answered");
    let gone = json!({"error": {"message": "no ticket", "data": {"reason": "not_found"}}});
    let relist = credentials.reply(again[0].id, &gone, &mut ids).unwrap()[0].clone();
    assert!(!credentials.refused);
    assert_eq!(credentials.reply(relist.id, &listing(vec![]), &mut ids), Some(vec![]));
    assert!(!credentials.needs_connection());
}

#[test]
fn a_removal_with_nothing_under_way_is_found_by_a_new_list() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    credentials.update(set(&["P1"]), None, &mut ids);
    let first = credentials.connected(&mut ids)[0].clone();
    let live = listing(vec![device("dv_p1", "phone-p1")]);
    assert_eq!(credentials.reply(first.id, &live, &mut ids), Some(vec![]));
    let list = credentials.update(set(&[]), None, &mut ids)[0].clone();
    assert_eq!(list.kind, Kind::List);
    let revoke_p1 = credentials.reply(list.id, &live, &mut ids).unwrap();
    assert_eq!(kinds(&revoke_p1), vec![revoke("dv_p1")]);
    let relist = credentials.reply(revoke_p1[0].id, &revoked(), &mut ids).unwrap()[0].clone();
    assert_eq!(credentials.reply(relist.id, &listing(vec![]), &mut ids), Some(vec![]));
    assert!(credentials.ending.is_empty());
}

#[test]
fn a_phone_listed_again_waits_for_its_unlisted_record_to_end() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    credentials.update(set(&["P1"]), Some(set(&[])), &mut ids);
    let first = credentials.connected(&mut ids)[0].clone();
    let revoke_old = credentials
        .reply(first.id, &listing(vec![device("dv_old", "phone-p1")]), &mut ids)
        .unwrap();
    assert_eq!(kinds(&revoke_old), vec![revoke("dv_old")], "unlisted: its record ends");
    assert!(
        credentials.update(set(&["P1"]), Some(set(&["P1"])), &mut ids).is_empty(),
        "no issue while it ends"
    );
    let relist = credentials.reply(revoke_old[0].id, &revoked(), &mut ids).unwrap()[0].clone();
    assert_eq!(relist.kind, Kind::List);
    assert_eq!(
        credentials.reply(relist.id, &listing(vec![]), &mut ids).map(|r| kinds(&r)),
        Some(vec![issue("P1")])
    );
}

#[test]
fn a_credential_issued_for_a_phone_removed_meanwhile_is_revoked() {
    let mut credentials = Credentials::default();
    let mut ids = 10;
    let first = connected(&mut credentials, &mut ids, &["P1"])[0].clone();
    assert!(credentials.update(set(&[]), Some(set(&[])), &mut ids).is_empty());
    assert_eq!(
        credentials.reply(first.id, &issued("dv_p1"), &mut ids).map(|r| kinds(&r)),
        Some(vec![revoke("dv_p1")])
    );
    assert!(credentials.tokens().is_empty());
    assert_eq!(
        credentials.reply(first.id, &issued("dv_p1"), &mut ids),
        None,
        "one reply per request"
    );
}

/// The same machine driven through `respond`, its state crossing as JSON each event, as the app keeps it.
#[test]
fn the_state_survives_the_json_round_trip() {
    let call = |request: Value| -> Value {
        serde_json::from_slice(&respond(&serde_json::to_vec(&request).unwrap()).unwrap()).unwrap()
    };
    let step = |state: &Value, ids: &Value, event: Value| {
        call(json!({"op": "credentials", "state": state, "ids": ids, "event": event}))
    };
    let fresh = call(
        json!({"op": "credentials", "ids": 10, "event": {"kind": "update", "paired": ["P1"], "listed": ["P1"]}}),
    );
    assert_eq!(fresh["requests"], json!([]));
    let up = step(&fresh["state"], &fresh["ids"], json!({"kind": "connected"}));
    assert_eq!(
        up["requests"],
        json!([{"id": 11, "kind": "list", "method": "_acpmux/pair_list", "params": {}}])
    );
    let listed = step(
        &up["state"],
        &up["ids"],
        json!({"kind": "reply", "id": 11, "message": listing(vec![])}),
    );
    assert_eq!(
        listed["requests"],
        json!([{"id": 12, "kind": "issue", "phone": "P1", "method": "_acpmux/pair_issue",
        "params": {"name": "phone-p1", "role": "phone"}}])
    );
    let got = step(
        &listed["state"],
        &listed["ids"],
        json!({"kind": "reply", "id": 12, "message": issued("dv_p1")}),
    );
    assert_eq!(got["tokens"], json!({"P1": "tok-dv_p1"}));
    assert_eq!(got["needsConnection"], json!(true));
    let again = step(
        &got["state"],
        &got["ids"],
        json!({"kind": "reply", "id": 12, "message": issued("dv_p1")}),
    );
    assert_eq!(again["requests"], Value::Null, "not one of these requests");
    let gone =
        step(&got["state"], &got["ids"], json!({"kind": "update", "paired": [], "listed": []}));
    assert_eq!(gone["requests"][0]["kind"], "revoke");
    assert_eq!(gone["requests"][0]["params"], json!({"id": "dv_p1"}));
    assert_eq!(gone["ending"], json!(["phone-p1"]));
    let down = step(&gone["state"], &gone["ids"], json!({"kind": "disconnected"}));
    assert_eq!(down["requests"], json!([]));
    assert!(respond(br#"{"op":"credentials","ids":1,"event":{"kind":"nope"}}"#).is_err());
}

#[test]
fn the_record_name_keeps_lowercased_ascii_letters_digits_and_dashes() {
    assert_eq!(acpmux_record_name("P1"), "phone-p1");
    assert_eq!(acpmux_record_name("AB12-Phone_9.x"), "phone-ab12-phone9x");
    assert_eq!(acpmux_record_name(&"a".repeat(100)), format!("phone-{}", "a".repeat(74)));
    assert_eq!(
        acpmux_record_name("e\u{301}x"),
        "phone-x",
        "a letter with a combining mark is not ASCII in Swift"
    );
}

fn seed_request() -> SeedRequest {
    SeedRequest {
        phone_device_id: "AB12-phone".into(),
        name: "cmux-mobile-e2e-ios26".into(),
        identity_key: format!("04{}", "aa".repeat(64)),
        approval_key: format!("04{}", "bb".repeat(64)),
    }
}

#[test]
fn only_the_named_phone_is_trusted() {
    let aa = "aa".repeat(64);
    let cc = "cc".repeat(64);
    let cases = [
        (r#"{"devices":[{"id":"ab12-phone"}]}"#.to_owned(), true),
        (r#"{"devices":[{"name":"cmux-mobile-e2e-ios26"}]}"#.to_owned(), true),
        (format!(r#"{{"devices":[{{"id":"ab12-phone","identityKey":"04{aa}"}}]}}"#), true),
        (format!(r#"{{"devices":[{{"id":"ab12-phone","identityKey":"04{cc}"}}]}}"#), false),
        (r#"{"devices":[{"id":"other"}]}"#.to_owned(), false),
        (r#"{"devices":[{}]}"#.to_owned(), false),
        ("not json".to_owned(), false),
    ];
    for (json, trusted) in cases {
        assert_eq!(trusts(Some(&json), &seed_request()), trusted, "{json}");
    }
    assert!(!trusts(None, &seed_request()), "an unreadable file trusts nothing");
    let reply: Value = serde_json::from_slice(&respond(&serde_json::to_vec(&json!({"op": "pairing_seed_trusts",
        "seed": r#"{"devices":[{"id":"AB12-PHONE"}]}"#, "request": {"phoneDeviceId": "ab12-phone", "name": "n",
        "identityKey": "", "approvalKey": ""}})).unwrap()).unwrap()).unwrap();
    assert_eq!(reply, json!({"trusts": true}));
}

const MAC: &str = "com.cmuxterm.app.debug.pair.fast.v1";
const PHONE: &str = "dev.cmux.mobile.pair-fast-v1";

/// Swift's `auto(bundleID:tag:environment:debugBuild:)`: BuildIdentity's kind is `dev` for a debug bundle.
fn auto(
    bundle_id: &str,
    tag: Option<&str>,
    approve_first: Option<&str>,
    debug_build: bool,
) -> Option<String> {
    let kind = if bundle_id.starts_with("com.cmuxterm.app.debug") { "dev" } else { "release" };
    auto_approve_tag(kind, Some(bundle_id), tag, approve_first, debug_build)
}

fn default_auto() -> Option<String> {
    auto(MAC, Some("pair-fast-v1"), None, true)
}

fn approve(
    kind: &str,
    bundle_id: Option<&str>,
    auto_tag: Option<&str>,
    paired: &str,
    account: Option<&str>,
) -> bool {
    approves(kind, bundle_id, auto_tag, paired, account)
}

#[test]
fn the_same_tags_phone_of_the_signed_in_user_pairs_without_the_prompt() {
    let tag = default_auto();
    assert_eq!(tag.as_deref(), Some("pair-fast-v1"));
    assert!(approve("phone", Some(PHONE), tag.as_deref(), "user-1", Some("user-1")));
    assert!(approve(
        "phone",
        Some("dev.cmux.mobile.Pair-Fast-V1"),
        tag.as_deref(),
        "user-1",
        Some("user-1")
    ));
}

#[test]
fn another_account_is_asked() {
    let tag = default_auto();
    assert!(!approve("phone", Some(PHONE), tag.as_deref(), "user-1", Some("user-2")));
    assert!(!approve("phone", Some(PHONE), tag.as_deref(), "user-2", Some("user-1")));
    assert!(!approve("phone", Some(PHONE), tag.as_deref(), "user-1", None));
    assert!(!approve("phone", Some(PHONE), tag.as_deref(), "", Some("")));
}

#[test]
fn another_tag_or_app_is_asked() {
    let tag = default_auto();
    for bundle_id in [
        Some("dev.cmux.mobile.other-tag"),
        Some("dev.cmux.mobile.pair-fast-v10"),
        Some("dev.cmux.mobile.pair-fast"),
        Some("dev.cmux.mobile"),
        Some("dev.cmux.mobile."),
        Some("com.cmux.app"),
        Some("dev.cmux.app.beta"),
        Some("com.cmux.app.pair-fast-v1"),
        Some(""),
        None,
    ] {
        assert!(
            !approve("phone", bundle_id, tag.as_deref(), "user-1", Some("user-1")),
            "{bundle_id:?}"
        );
    }
}

#[test]
fn a_machine_is_asked() {
    let tag = default_auto();
    assert!(!approve("mac", Some(PHONE), tag.as_deref(), "user-1", Some("user-1")));
    assert!(!approve("linux", Some(PHONE), tag.as_deref(), "user-1", Some("user-1")));
}

#[test]
fn nightly_rc_staging_and_release_builds_never_auto_approve() {
    for bundle_id in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.staging.pair-fast-v1",
        "com.cmuxterm.app.next",
        "com.cmux.app",
    ] {
        assert_eq!(auto(bundle_id, Some("pair-fast-v1"), None, true), None, "{bundle_id}");
        // The bundle id rule holds even if the kind said dev.
        assert_eq!(
            auto_approve_tag("dev", Some(bundle_id), Some("pair-fast-v1"), None, true),
            None,
            "{bundle_id}"
        );
    }
    assert_eq!(auto("com.cmuxterm.app.debug", None, None, true), None);
    assert_eq!(auto(MAC, Some(""), None, true), None);
    assert_eq!(auto(MAC, Some("pair-fast-v1"), None, false), None);
    assert!(!approve("phone", Some(PHONE), None, "user-1", Some("user-1")));
}

#[test]
fn approve_first_keeps_the_prompt() {
    assert_eq!(APPROVE_FIRST_KEY, "CMUX_NEXT_IPHONE_APPROVE_FIRST");
    assert_eq!(auto(MAC, Some("pair-fast-v1"), Some("1"), true), None);
    assert!(auto(MAC, Some("pair-fast-v1"), Some("0"), true).is_some());
}

#[test]
fn another_builds_dev_phone_asks_quietly() {
    assert!(asks_quietly("phone", Some(PHONE), Some("cu-all")));
    assert!(asks_quietly("phone", Some(PHONE), None));
    assert!(!asks_quietly("phone", Some(PHONE), Some("pair-fast-v1")));
    for bundle_id in
        [Some("com.cmux.app"), Some("dev.cmux.app.beta"), Some("dev.cmux.mobile."), None]
    {
        assert!(!asks_quietly("phone", bundle_id, None), "{bundle_id:?}");
    }
    assert!(!asks_quietly("mac", Some(PHONE), None));
    assert_eq!(dev_tag("dev", Some(MAC), Some("pair-fast-v1")).as_deref(), Some("pair-fast-v1"));
    assert_eq!(dev_tag("nightly", Some("com.cmuxterm.app.nightly"), None), None);
}

#[test]
fn a_quiet_request_never_auto_approves() {
    let other = auto("com.cmuxterm.app.debug.cu.all", Some("cu-all"), None, true);
    assert!(asks_quietly("phone", Some(PHONE), other.as_deref()));
    assert!(!approve("phone", Some(PHONE), other.as_deref(), "user-1", Some("user-1")));
    assert!(asks_quietly("phone", Some(PHONE), None));
    let tag = default_auto();
    assert!(approve("phone", Some(PHONE), tag.as_deref(), "user-1", Some("user-1")));
    assert!(!asks_quietly("phone", Some(PHONE), tag.as_deref()));
    let reply: Value = serde_json::from_slice(&respond(&serde_json::to_vec(&json!({"op": "dev_request", "kind": "phone",
        "bundleId": PHONE, "macDevTag": "cu-all", "autoTag": "cu-all", "pairedUserId": "u", "accountUserId": "u"}))
        .unwrap()).unwrap()).unwrap();
    assert_eq!(reply, json!({"phoneTag": "pair-fast-v1", "asksQuietly": true, "approves": false}));
}
