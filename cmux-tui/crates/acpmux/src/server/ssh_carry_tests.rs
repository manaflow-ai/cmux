/// Duress harness: 416 queued deliveries to one host whose ssh login refuses, each retried
/// every 2 s for an hour (the herd a link flap woke). Carries that spawn ssh: one per
/// cool-down step, not one per delivery per retry.
#[test]
fn a_refusing_host_gets_one_carry_per_cool_down_not_one_per_delivery() {
    let start = std::time::Instant::now();
    let mut cool = super::Cooldown::default();
    let mut spawned = 0u32;
    for tick in 0..1800u64 {
        let now = start + std::time::Duration::from_secs(tick * 2);
        for _ in 0..416 {
            if !cool.cooling("h", now) {
                spawned += 1;
                cool.record("h", true, now);
            }
        }
    }
    eprintln!("ssh carries in 1 h for 416 deliveries: {spawned} (was {})", 1800 * 416);
    // At 0, 60, 180, 420, 900, 1800 and 2700 s (waits 60, 120, 240, 480, then 900): 7.
    assert_eq!(spawned, 7);
    // Another host is not held back by this one; a carry that reached a host clears it.
    assert!(!cool.cooling("other", start));
    let late = start + std::time::Duration::from_secs(3600);
    cool.record("h", false, late);
    assert!(!cool.cooling("h", late));
}

use super::*;

/// Review of #53719, F2: `carry` itself skips the ssh login while the host cools down. 416
/// deliveries to one refusing ssh host: one login, the rest not carried; another hub's own
/// cool-down is its own, so it logs in once too.
#[tokio::test]
async fn carry_skips_a_cooling_host_and_each_hub_has_its_own_cool_down() {
    static LOGINS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    fn refused(_: Vec<String>, _: Vec<u8>) -> Carry {
        LOGINS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Carry::NotTaken("ssh: connect to host box port 22: Connection refused".into())
    }
    let hub = || {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let row = json!({"sessionId": "s-lane", "name": "lane", "status": "idle",
                         "turnCount": 1, "updatedAt": 5});
        hub.seed_down_peer_at("carry-cool-box", "ssh://carry-cool-box", vec![row]);
        hub
    };
    let mut d = delivery(json!({"promptId": "p"}));
    d.target = "carry-cool-box/lane".into();
    let (one, two) = (hub(), hub());
    assert!(route(&one, &d.target).is_some(), "no ssh route to the down peer");
    let mut carried = 0;
    for _ in 0..416 {
        carried += u32::from(carry_by(&one, &d, refused).await.is_some());
    }
    assert_eq!((carried, LOGINS.load(std::sync::atomic::Ordering::SeqCst)), (1, 1));
    assert!(carry_by(&two, &d, refused).await.is_some(), "another hub's cool-down held it");
    assert_eq!(LOGINS.load(std::sync::atomic::Ordering::SeqCst), 2);
    // A carry that reached the host clears its cool-down for the next one.
    one.ssh_carry_cooldown.lock().unwrap().record(
        "carry-cool-box",
        false,
        std::time::Instant::now(),
    );
    assert!(carry_by(&one, &d, refused).await.is_some());
    assert_eq!(LOGINS.load(std::sync::atomic::Ordering::SeqCst), 3);
}

#[test]
fn the_message_goes_on_stdin_and_every_word_is_quoted() {
    let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi; rm -rf ~"}],
        "_meta": {"acpmux": {"promptId": "p-1", "steer": true, "class": "question"}}});
    let m = message(&request, &Sender::Named("co'ord".into()), "vm-1").unwrap();
    assert_eq!(m.text, "hi; rm -rf ~");
    let s = script("lane x", &m.flags);
    assert!(!s.contains("rm -rf"), "{s}");
    assert!(s.contains("'--prompt-id=p-1'"), "{s}");
    assert!(s.contains("'--steer'"), "{s}");
    assert!(s.contains("'--class=question'"), "{s}");
    assert!(s.contains(r"'--from=co'\''ord'"), "{s}");
    assert!(s.contains(r"'--relayed-from=vm-1/co'\''ord'"), "{s}");
    assert!(s.contains("'lane x' -;"), "{s}");
    assert!(s.starts_with("for a in \"$HOME/.local/bin/acpmux\" acpmux;"), "{s}");
}

#[test]
fn an_attachment_or_no_prompt_id_is_not_carried() {
    let image = json!({"prompt": [{"type": "text", "text": "x"}, {"type": "image", "data": ""}],
        "_meta": {"acpmux": {"promptId": "p"}}});
    assert_eq!(message(&image, &Sender::Person, "m"), None);
    let bare = json!({"prompt": [{"type": "text", "text": "x"}]});
    assert_eq!(message(&bare, &Sender::Person, "m"), None);
}

/// A delivery with `mux` as its request's `_meta.acpmux`.
fn delivery(mux: Value) -> Delivery {
    let request = json!({"sessionId": "box/lane", "prompt": [{"type": "text", "text": "hi"}],
        "_meta": {"acpmux": mux}});
    serde_json::from_value(json!({"id": "d-1", "target": "box/lane", "request": request,
        "state": "queued", "createdAt": 0, "updatedAt": 0}))
    .unwrap()
}

/// Only the person's own send is carried with no sender: every other one names its sender
/// or, with no name to give, this machine as its relay, so the far daemon never records an
/// agent's message as its owner's terminal send.
#[test]
fn only_the_persons_own_send_is_carried_with_no_sender() {
    let name_of = |id: &str| format!("name-of-{id}");
    let flags = |d: &Delivery| message(&d.request, &sender(d, name_of), "vm-1").unwrap().flags;
    let relayed = |flags: &[String]| flags.iter().any(|f| f.starts_with("--relay="));

    let person = delivery(json!({"promptId": "p"}));
    assert_eq!(sender(&person, name_of), Sender::Person);
    assert!(!relayed(&flags(&person)), "{:?}", flags(&person));

    let mut proven = delivery(json!({"promptId": "p"}));
    proven.caller = Some("s1".into());
    assert_eq!(sender(&proven, name_of), Sender::Named("name-of-s1".into()));

    // The case of 2026-11-22: a stale caller token, so the session is named and unproven.
    let mut unproven = delivery(json!({"promptId": "p"}));
    unproven.unproven_caller = Some("s2".into());
    assert_eq!(sender(&unproven, name_of), Sender::Named("name-of-s2".into()));
    let f = flags(&unproven);
    assert!(f.contains(&"--from=name-of-s2".to_owned()), "{f:?}");
    assert!(f.contains(&"--relayed-from=vm-1/name-of-s2".to_owned()), "{f:?}");

    // An agent's shell that declared no terminal and named no one.
    let mut no_terminal = delivery(json!({"promptId": "p"}));
    no_terminal.not_terminal = true;
    assert_eq!(sender(&no_terminal, name_of), Sender::Program);
    let f = flags(&no_terminal);
    assert!(f.contains(&"--relay=acpmux-ssh".to_owned()), "{f:?}");
    assert!(f.contains(&"--relayed-from=vm-1".to_owned()), "{f:?}");
    assert!(!f.iter().any(|flag| flag.starts_with("--from=")), "{f:?}");

    // Each claim that makes a direct send a program's does the same for a carried one.
    for key in ["fromHarness", "senderHarness", "fromRelay", "via"] {
        let claimed = delivery(json!({"promptId": "p", key: {"harness": "claude-code"}}));
        assert_eq!(sender(&claimed, name_of), Sender::Program, "{key}");
        assert!(relayed(&flags(&claimed)), "{key}");
    }
    let named = delivery(json!({"promptId": "p", "fromAgent": "vm-9/lane", "via": "x"}));
    assert_eq!(sender(&named, name_of), Sender::Named("vm-9/lane".into()));
    // A blank name is no name, and still not the person's.
    let blank = delivery(json!({"promptId": "p", "fromAgent": "  "}));
    assert_eq!(sender(&blank, name_of), Sender::Program);
}

#[test]
fn a_key_ssh_could_read_as_an_option_is_never_carried() {
    assert!(!plain_key("-oProxyCommand=x"));
    assert!(!plain_key(""));
    assert!(!plain_key("a\nb"));
    assert!(plain_key("lane-1"));
}

#[test]
fn what_the_far_side_said_decides_the_outbox_next_step() {
    let ok = r#"{"deliveryId": "d-9", "promptId": "p", "sessionId": "s", "status": "queued", "steered": false}"#;
    match outcome(Some(0), ok, "") {
        Carry::Taken(v) => {
            assert_eq!(v["sshDeliveryId"], "d-9");
            assert_eq!(v["via"], "ssh");
        }
        other => panic!("{other:?}"),
    }
    assert!(matches!(outcome(Some(0), "not json", ""), Carry::Maybe(_)));
    assert!(matches!(
        outcome(Some(255), "", "ssh: connect to host box port 22: Connection refused"),
        Carry::NotTaken(_)
    ));
    assert!(matches!(
        outcome(Some(255), "", "Connection to box closed by remote host."),
        Carry::Maybe(_)
    ));
    // A parked machine behind a relay ProxyCommand: ssh never logged in, so the message is
    // still unsent and the mesh relay may carry it (not a maybe-taken that rules it out).
    assert!(matches!(
        outcome(
            Some(255),
            "",
            "mm_receive_fd: recvmsg: expected received 1 got 0\nproxy dialer did not pass back a connection"
        ),
        Carry::NotTaken(_)
    ));
    assert!(matches!(outcome(Some(127), "", "acpmux: not found"), Carry::NotTaken(_)));
    assert!(matches!(outcome(Some(4), "", "no session"), Carry::NotTaken(_)));
    assert!(matches!(outcome(Some(1), "", "boom"), Carry::Maybe(_)));
    assert!(matches!(outcome(None, "", ""), Carry::Maybe(_)));
}
