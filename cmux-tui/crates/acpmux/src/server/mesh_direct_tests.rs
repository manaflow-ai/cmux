//! The direct send's rules on each side (`mesh_direct.rs`): the switch is off unless set, the far
//! side runs a prompt for one of the person's sessions only, under one id per post, from the
//! machine the circuit proved, and the sending side reads each answer as run, not run, or maybe.

use super::*;
use crate::mesh::{HubError, Kind, Mode, Sender, Target};
use crate::mesh_relay_config::MeshRelayConfig;

fn post(key: &str) -> OutMessage {
    OutMessage {
        to: Target {
            name: Some("lane".into()),
            host: Some("far-host".into()),
            daemon_id: Some("inst_b".into()),
            ..Target::default()
        },
        from: Sender {
            name: Some("worker".into()),
            host: Some("claimed-host".into()),
            daemon_id: Some("claimed-daemon".into()),
            user: Some("claimed-user".into()),
            team_address: Some("@claimed/team".into()),
            ..Sender::default()
        },
        kind: Kind::Prompt,
        op: None,
        body: "hello".into(),
        mode: Mode::TurnEnd,
        idempotency_key: key.into(),
    }
}

fn code(e: &RpcError) -> Option<&str> {
    e.data.as_ref()?.get("code")?.as_str()
}

#[test]
fn the_switch_is_off_unless_the_person_sets_it() {
    assert!(!MeshRelayConfig::default().direct_send);
    let read: MeshRelayConfig =
        serde_json::from_value(json!({"url": "https://hub.example", "tokenCommand": ["t"]}))
            .unwrap();
    assert!(!read.direct_send, "absent reads as off");
    let written = serde_json::to_value(&read).unwrap();
    assert!(written.get("directSend").is_none(), "off is not written: {written}");
    let on: MeshRelayConfig = serde_json::from_value(
        json!({"url": "https://hub.example", "tokenCommand": ["t"], "directSend": true}),
    )
    .unwrap();
    assert!(on.direct_send);
}

#[test]
fn only_a_failure_that_never_left_proves_the_hub_holds_nothing() {
    assert!(HubError::unconnected("refused to connect").never_reached());
    assert!(HubError::local("token command failed").never_reached());
    assert!(
        !HubError::unavailable("no answer within 10s").never_reached(),
        "a timeout may hold it"
    );
    assert!(!HubError::refused("the hub answered 400").never_reached(), "an answer is not unsent");
}

#[test]
fn a_copy_is_one_prompt_from_the_proven_machine_whatever_the_attempt() {
    let first = in_message("inst_a", &post("prompt-0001"), 1).unwrap();
    let again = in_message("inst_a", &post("prompt-0001"), 7).unwrap();
    assert_eq!(first.message_id, "direct:inst_a:prompt-0001");
    assert_eq!(first.message_id, again.message_id, "the same post is the same prompt");
    assert_eq!(again.attempt, 7);
    assert_eq!(in_message("inst_a", &post("prompt-0001"), 0).unwrap().attempt, 1);
    // From the machine the Noise handshake proved, never what the request says.
    assert_eq!(first.from.daemon_id.as_deref(), Some("inst_a"));
    assert_eq!(first.from.host, None);
    assert_eq!(first.from.user, None);
    assert_eq!(first.from.team_address, None);
    assert_eq!(first.from.name.as_deref(), Some("worker"));
    // For a session here, by name or id: the circuit already chose the machine.
    assert_eq!(first.to.host, None);
    assert_eq!(first.to.daemon_id, None);
    assert_eq!(first.to.name.as_deref(), Some("lane"));
    assert_eq!(first.kind, Kind::Prompt);
    assert_eq!(first.start_work, None, "no hub decision is claimed");
    // Another sender's copy of the same key is another prompt.
    assert_ne!(in_message("inst_c", &post("prompt-0001"), 1).unwrap().message_id, first.message_id);
}

#[test]
fn a_copy_that_is_not_a_plain_prompt_is_refused_before_it_runs() {
    let mut control = post("prompt-0002");
    control.kind = Kind::Control;
    control.op = Some("stop".into());
    let mut team = post("prompt-0003");
    team.to.team_address = Some("@team/role".into());
    let mut op = post("prompt-0004");
    op.op = Some("start".into());
    for (name, bad) in [
        ("control", control),
        ("team", team),
        ("op", op),
        ("short key", post("k")),
        ("odd key", post("prompt 0005 ✓")),
        ("long key", post(&"k".repeat(129))),
    ] {
        let e = in_message("inst_a", &bad, 1).expect_err(name);
        assert_eq!(code(&e), Some(BAD_REQUEST), "{name}: {e:?}");
    }
}

#[test]
fn the_far_side_answers_run_refused_or_later() {
    let ran = answer(Some(crate::mesh::Ack::delivered("direct:inst_a:k", None))).unwrap();
    assert_eq!(ran["promptId"], "direct:inst_a:k");
    let no = answer(Some(crate::mesh::Ack::refused("no session lane here"))).unwrap_err();
    assert_eq!(code(&no), Some(REFUSED));
    let later = answer(None).unwrap_err();
    assert_eq!(code(&later), Some(LATER));
}

#[test]
fn the_sender_reads_each_answer_as_taken_not_run_or_maybe() {
    let p = post("prompt-0006");
    let taken = outcome(&p, "far-host", Ok(json!({"promptId": "direct:inst_a:prompt-0006"})));
    let Direct::Taken(accepted) = taken else { panic!("{taken:?}") };
    assert_eq!(accepted["via"], "direct");
    assert_eq!(accepted["promptId"], "direct:inst_a:prompt-0006");
    assert!(matches!(outcome(&p, "far-host", Err(None)), Direct::Maybe(_)), "no answer: maybe");
    let far = |c: &str| Err(Some(refused(c, "why")));
    assert!(matches!(outcome(&p, "far-host", far(REFUSED)), Direct::Refused(_)));
    for c in [OFF, UNLISTED, BAD_REQUEST] {
        assert!(matches!(outcome(&p, "far-host", far(c)), Direct::NotRun(_)), "{c}");
    }
    // A build there with no direct send ran nothing.
    let old = Err(Some(RpcError::method_not_found(METHOD)));
    assert!(matches!(outcome(&p, "far-host", old), Direct::NotRun(_)));
    // Anything it may still act on is a maybe: only a direct copy goes again.
    assert!(matches!(outcome(&p, "far-host", far(LATER)), Direct::Maybe(_)));
    assert!(matches!(outcome(&p, "far-host", far("something.new")), Direct::Maybe(_)));
    let internal = Err(Some(RpcError::internal("boom")));
    assert!(matches!(outcome(&p, "far-host", internal), Direct::Maybe(_)));
}

#[cfg(feature = "hub-carrier")]
mod far_side {
    use super::*;
    use crate::config::{Config, StoreMode};

    fn hub() -> std::sync::Arc<Hub> {
        let mut config = Config::default();
        config.store.mode = StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(config, store)
    }

    fn params() -> Value {
        json!({"message": post("prompt-0007"), "attempt": 1})
    }

    #[tokio::test]
    async fn a_far_daemon_with_the_switch_off_runs_nothing() {
        let hub = hub();
        let machines = [("inst_a".to_owned(), "near-host".to_owned())].into_iter().collect();
        hub.set_mesh_book_machines(machines);
        let e = run_from(&hub, "inst_a", &params()).await.unwrap_err();
        assert_eq!(code(&e), Some(OFF), "{e:?}");
    }

    #[tokio::test]
    async fn a_far_daemon_runs_nothing_from_a_machine_its_book_does_not_list() {
        let hub = hub();
        hub.config.write().await.mesh_relay =
            Some(MeshRelayConfig { direct_send: true, ..MeshRelayConfig::default() });
        let machines = [("inst_a".to_owned(), "near-host".to_owned())].into_iter().collect();
        hub.set_mesh_book_machines(machines);
        let e = run_from(&hub, "inst_z", &params()).await.unwrap_err();
        assert_eq!(code(&e), Some(UNLISTED), "{e:?}");
        let e = run_from(&hub, "inst_a", &json!({"message": "not one"})).await.unwrap_err();
        assert_eq!(code(&e), Some(BAD_REQUEST), "{e:?}");
        // Listed and on: it reaches delivery, which names no session `lane` here.
        let e = run_from(&hub, "inst_a", &params()).await.unwrap_err();
        assert_eq!(code(&e), Some(REFUSED), "{e:?}");
    }

    #[test]
    fn the_book_names_the_machine_by_daemon_id_then_by_host() {
        let hub = hub();
        let machines = [
            ("inst_b".to_owned(), "far-host".to_owned()),
            ("inst_c".to_owned(), "twin".to_owned()),
            ("inst_d".to_owned(), "twin".to_owned()),
        ]
        .into_iter()
        .collect();
        hub.set_mesh_book_machines(machines);
        let mut p = post("prompt-0008");
        assert_eq!(machine(&hub, &p), Some(("inst_b".into(), "far-host".into())));
        p.to.daemon_id = None;
        assert_eq!(machine(&hub, &p), Some(("inst_b".into(), "far-host".into())));
        p.to.host = Some("twin".into());
        assert_eq!(machine(&hub, &p), None, "two machines by that name: neither");
        p.to.host = Some("elsewhere".into());
        assert_eq!(machine(&hub, &p), None);
    }
}
