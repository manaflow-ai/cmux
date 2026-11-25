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
    let (route, why) = pick(Ok(verdict(false)), || panic!("read the account with room"));
    assert_eq!(route, None);
    assert_eq!(why, "this Mac has room (for 3 more)");
    let (route, why) = pick(Ok(verdict(true)), signed_in);
    assert_eq!(route, Some(Route::Cloud(Machine::New)));
    assert!(why.starts_with("this Mac is busy (no room: RAM is the limit)"), "{why}");
    assert_eq!(pick(Ok(verdict(true)), Account::default).0, None);
    let disabled = || Account { cloud_disabled: true, ..signed_in() };
    assert_eq!(pick(Ok(verdict(true)), disabled).0, None);
    assert_eq!(pick(Err("no acpmux".into()), signed_in).0, None);
    let no_hybrid = || Account { flag: Some(false), ..signed_in() };
    let (route, why) = pick(Ok(verdict(true)), no_hybrid);
    assert_eq!(route, None);
    assert!(why.contains("hybrid chats are not on"), "{why}");
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
