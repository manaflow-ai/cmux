use super::*;
use serde_json::json;

fn start(list: &[&str]) -> Start {
    let words: Vec<String> = list.iter().map(|w| (*w).to_owned()).collect();
    match super::super::parse(&words, None).unwrap() {
        super::super::Parsed::Run(start) => start,
        super::super::Parsed::Help => panic!("help"),
    }
}

fn verdict(busy: bool) -> Value {
    json!({"hosts": [{"name": "mac", "local": true, "room": if busy { 0.0 } else { 3.0 },
        "load": busy, "refused": busy.then_some("no room: RAM is the limit")}]})
}

fn signed_in() -> Account {
    Account { signed_in: true, flag: Some(true), ..Account::default() }
}

/// A chat nobody placed: here with room (the account is never read), a new Cloud VM when
/// this Mac is busy and Cloud takes it, here when it cannot or acpmux gave no verdict.
#[test]
fn auto_starts_here_with_room_else_on_a_new_cloud_vm() {
    let (route, why) = pick(Ok(verdict(false)), || panic!("read the account with room"), false);
    assert_eq!(route, None);
    assert_eq!(why, "this Mac has room (for 3 more)");
    let (route, why) = pick(Ok(verdict(true)), signed_in, false);
    assert_eq!(route, Some(Route::Cloud(Machine::New)));
    assert!(why.starts_with("this Mac is busy (no room: RAM is the limit)"), "{why}");
    assert_eq!(pick(Ok(verdict(true)), Account::default, false).0, None);
    let disabled = || Account { cloud_disabled: true, ..signed_in() };
    assert_eq!(pick(Ok(verdict(true)), disabled, false).0, None);
    assert_eq!(pick(Err("no acpmux".into()), signed_in, false).0, None);
    let no_hybrid = || Account { flag: Some(false), ..signed_in() };
    let (route, why) = pick(Ok(verdict(true)), no_hybrid, false);
    assert_eq!(route, None);
    assert!(why.contains("hybrid chats are not on"), "{why}");
}

fn verdict_enrolled() -> Value {
    json!({"hosts": [
        {"name": "mac", "local": true, "room": 0.0, "load": true,
         "refused": "no room: RAM is the limit"},
        {"name": "studio", "local": false, "room": 6.0, "load": false,
         "autoCloud": {"v": 1, "enrolled": true, "accepting": true, "caps": ["macos"]}},
        {"name": "desk", "local": false, "room": 9.0, "load": false,
         "autoCloud": {"v": 1, "enrolled": true, "accepting": false,
            "why": "owner active (away 4s of 600s)", "caps": ["macos"]}}]})
}

/// AutoCloud on: a busy Mac's chat goes to the enrolled, idle peer (never the one whose
/// owner is at it) before Cloud, with no account read needed for it. Off: as before.
#[test]
fn auto_with_autocloud_on_places_on_an_enrolled_idle_peer() {
    let (route, why) = pick(Ok(verdict_enrolled()), signed_in, true);
    assert_eq!(route, Some(Route::Peer("studio".into())), "{why}");
    assert!(why.contains("enrolled in AutoCloud and idle"), "{why}");
    let (route, _) = pick(Ok(verdict_enrolled()), signed_in, false);
    assert_eq!(route, Some(Route::Cloud(Machine::New)));
    // An older acpmux's verdict (no autoCloud on any row): as before.
    let (route, _) = pick(Ok(verdict(true)), signed_in, true);
    assert_eq!(route, Some(Route::Cloud(Machine::New)));
}

/// Auto weighs only a start a Cloud VM runs the same: no target named, nothing of this
/// Mac's own in it.
#[test]
fn auto_weighs_only_a_start_with_nothing_of_this_macs_own() {
    assert!(applies(&start(&["--prompt", "hi"])));
    assert!(applies(&start(&[])));
    assert!(!applies(&start(&["--on", "here", "--prompt", "hi"])));
    assert!(!applies(&start(&["--on", "vm:new", "--prompt", "hi"])));
    assert!(!applies(&start(&["--cwd", "/tmp", "--prompt", "hi"])));
    assert!(!applies(&start(&["--environment", "env_1", "--prompt", "hi"])));
}
