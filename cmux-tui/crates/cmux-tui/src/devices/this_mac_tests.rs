use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};

use super::{ThisMac, ensure, listed};

const HUB: &str = "https://hub.example";

/// A cmux access token for user `u_leo` (unsigned: only its claims are read here).
fn token() -> String {
    let part = |value: Value| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value.to_string().as_bytes())
    };
    format!(
        "{}.{}.sig",
        part(json!({"alg": "ES256"})),
        part(json!({"iss": "https://cmux-api/dev", "sub": "u_leo", "team": "team_1"}))
    )
}

/// Every `cmux acp` call made, with what it read on stdin; `answer` gives each one's reply.
struct Fake {
    calls: Vec<(Vec<String>, Option<String>)>,
}

impl Fake {
    fn run<'a>(
        &'a mut self,
        answer: impl Fn(&[&str]) -> Result<Value, Value> + 'a,
    ) -> impl FnMut(&[&str], Option<&str>) -> Result<Value, Value> + 'a {
        move |words, stdin| {
            self.calls
                .push((words.iter().map(|w| (*w).to_owned()).collect(), stdin.map(str::to_owned)));
            answer(words)
        }
    }
}

fn enroll_answer(outcome: &'static str) -> impl Fn(&[&str]) -> Result<Value, Value> {
    move |words| match words.first().copied() {
        Some("machine") => Ok(json!({"outcome": outcome})),
        _ => Ok(json!({"ok": true})),
    }
}

/// Door A timing run (huge-blue/doora-timing, 2026-11-16): the Mac that ran `cmux device add`
/// was never joined to the hub, so `cmux chat --on joined:<id>` answered "mesh enqueue key ...;
/// error runtime". The add joins this Mac as the person whose token it used, the token on stdin
/// only, and restarts its daemon onto the join, whose relay starts only at its start.
#[test]
fn device_add_joins_the_mac_that_ran_it_as_the_same_person() {
    let token = token();
    let mut fake = Fake { calls: Vec::new() };
    let done = ensure(HUB, &token, &mut fake.run(enroll_answer("joined")));
    assert_eq!(done, ThisMac::Joined);
    let (words, stdin) = &fake.calls[0];
    assert_eq!(
        words,
        &[
            "machine",
            "enroll-self",
            "--access-token-stdin",
            "--hub",
            HUB,
            "--user-id",
            "u_leo",
            "--json"
        ]
    );
    assert_eq!(stdin.as_deref(), Some(format!("{token}\n").as_str()));
    assert!(!words.iter().any(|word| word.contains(&token)), "the token is never an argument");
    assert_eq!(fake.calls[1].0, ["daemon", "restart", "--json"]);
    assert_eq!(fake.calls.len(), 2);
}

/// A Mac signing in already joined changes nothing: no restart.
#[test]
fn a_mac_already_on_the_mesh_is_left_running() {
    let mut fake = Fake { calls: Vec::new() };
    assert_eq!(
        ensure(HUB, &token(), &mut fake.run(enroll_answer("alreadyJoined"))),
        ThisMac::Ready
    );
    assert_eq!(fake.calls.len(), 1, "{:?}", fake.calls);
}

/// A join that is not this person's, or not this hub's, is never replaced: said, with a next step.
#[test]
fn a_mac_joined_some_other_way_is_left_alone_and_said_so() {
    for outcome in ["otherUser", "otherHub", "ownRelay", "revoked", "ownerUnknown", "unavailable"] {
        let mut fake = Fake { calls: Vec::new() };
        let done = ensure(HUB, &token(), &mut fake.run(enroll_answer(outcome)));
        let ThisMac::Blocked { message, next } = done else { panic!("{outcome}: {done:?}") };
        assert!(!message.is_empty() && !next.is_empty(), "{outcome}");
        assert_eq!(fake.calls.len(), 1, "{outcome}: nothing restarts");
    }
    // A token that names no one enrolls nothing.
    let mut fake = Fake { calls: Vec::new() };
    let done = ensure(HUB, "not-a-jwt", &mut fake.run(enroll_answer("joined")));
    assert!(matches!(done, ThisMac::Blocked { .. }), "{done:?}");
    assert!(fake.calls.is_empty());
}

/// The add waits for the hub to list the machine by the name it printed.
#[test]
fn the_add_waits_for_the_hub_to_list_the_machine_by_its_name() {
    let mut reads = 0;
    let mut acp = |_: &[&str], _: Option<&str>| {
        reads += 1;
        let peers = if reads < 2 {
            json!([{"name": "box", "connected": true}])
        } else {
            json!([{"name": "doora-vm-1", "connected": true, "via": "hub"}])
        };
        Ok(json!({"peers": peers}))
    };
    assert!(listed("doora-vm-1", Duration::from_secs(5), &mut acp));
    let mut never = |_: &[&str], _: Option<&str>| {
        Ok(json!({"peers": [{"name": "doora-vm-1", "connected": true}]}))
    };
    assert!(
        !listed("doora-vm-1", Duration::from_millis(10), &mut never),
        "a direct peer is no hub row"
    );
}
