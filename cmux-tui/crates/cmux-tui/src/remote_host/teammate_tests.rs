//! Teammate access (plans/cmux-next/teammate-access-DESIGN.md): who a
//! teammate's listener admits, with which scopes, and what it logs.

use std::net::IpAddr;

use super::admit::{Decision, decide};
use super::audit;
use super::config::Config;
use super::grant::{self, Grant, Scope};
use super::tailnet::Identity;

const LAWRENCE: &str = "lawrence@manaflow.ai";
const LEO: &str = "leo@manaflow.ai";

fn ip(s: &str) -> IpAddr {
    s.parse().unwrap()
}

/// Leo's machine: hosting on, Leo the owner, teammate access on, one grant.
fn leo_host(grant: Grant) -> Config {
    Config {
        enabled: true,
        owner: Some(LEO.to_owned()),
        teammate_access: true,
        grants: vec![grant],
        ..Config::default()
    }
}

fn consented(login: &str, scopes: &[Scope]) -> Grant {
    Grant {
        login: login.to_owned(),
        scopes: scopes.to_vec(),
        consented_at: Some("2026-10-20T09:00:00Z".to_owned()),
        consented_via: Some("cli-tty".to_owned()),
        revoked_at: None,
    }
}

fn person(login: &str) -> anyhow::Result<Identity> {
    Ok(Identity {
        login: Some(login.to_owned()),
        node: "lawrence-mbp".to_owned(),
        tags: vec![],
        shared: false,
    })
}

const SELF: &str = "100.70.1.1";
const PEER: &str = "100.80.2.2";

fn decide_for(config: &Config, peer: &str, identity: anyhow::Result<Identity>) -> Decision {
    decide(config, &[ip(SELF)], ip(peer), identity)
}

#[test]
fn consented_grant_admits_lawrence_as_guest_with_its_scopes() {
    let config = leo_host(consented(LAWRENCE, &[Scope::Status]));
    match decide_for(&config, PEER, person(LAWRENCE)) {
        Decision::Guest(identity, scopes) => {
            assert_eq!(identity.login.as_deref(), Some(LAWRENCE));
            assert_eq!(scopes, vec![Scope::Status]);
        }
        other => panic!("expected guest, got {other:?}"),
    }
    assert_eq!(decide_for(&config, PEER, person(LAWRENCE)).access(), Some("guest"));
}

#[test]
fn refuses_a_peer_that_is_not_on_the_tailnet() {
    let config = leo_host(consented(LAWRENCE, &[Scope::Status, Scope::Shell]));
    for peer in ["192.168.1.20", "8.8.8.8", "10.0.0.5", "2001:db8::1"] {
        assert!(
            matches!(decide_for(&config, peer, person(LAWRENCE)), Decision::Refused(_)),
            "{peer} must be refused"
        );
    }
}

#[test]
fn refuses_an_identity_that_is_not_on_the_teammate_allowlist() {
    // Leo granted someone else: the grant exists and is consented, but only
    // the compiled-in allowlist may hold teammate grants.
    let config = leo_host(consented("mallory@example.com", &[Scope::Status]));
    assert!(matches!(
        decide_for(&config, PEER, person("mallory@example.com")),
        Decision::Refused(_)
    ));
    // And a tailnet user without any grant is refused too.
    let config = leo_host(consented(LAWRENCE, &[Scope::Status]));
    assert!(matches!(decide_for(&config, PEER, person("aziz@manaflow.ai")), Decision::Refused(_)));
    assert!(!grant::on_allowlist("mallory@example.com"));
    assert!(grant::on_allowlist("Lawrence@Manaflow.ai"));
}

#[test]
fn refuses_before_consent() {
    let mut pending = consented(LAWRENCE, &[Scope::Status]);
    pending.consented_at = None;
    let config = leo_host(pending);
    assert_eq!(
        decide_for(&config, PEER, person(LAWRENCE)),
        Decision::Refused("teammate access is waiting for approval on this machine")
    );
}

#[test]
fn refuses_after_revoke() {
    let mut revoked = consented(LAWRENCE, &[Scope::Status]);
    revoked.revoked_at = Some("2026-10-20T10:00:00Z".to_owned());
    let config = leo_host(revoked);
    assert!(matches!(decide_for(&config, PEER, person(LAWRENCE)), Decision::Refused(_)));
}

#[test]
fn grants_are_ignored_while_the_setting_is_off() {
    let mut config = leo_host(consented(LAWRENCE, &[Scope::Status]));
    config.teammate_access = false;
    assert!(matches!(decide_for(&config, PEER, person(LAWRENCE)), Decision::Refused(_)));
    // The setting defaults to off, and so does an old remote.json without it.
    assert!(!Config::default().teammate_access);
    let old: Config = serde_json::from_str(r#"{"version":1,"enabled":true}"#).unwrap();
    assert!(!old.teammate_access);
    assert!(old.grants.is_empty());
}

#[test]
fn refuses_tagged_and_shared_nodes_even_with_a_grant() {
    let config = leo_host(consented(LAWRENCE, &[Scope::Status]));
    let tagged =
        Identity { login: None, node: "ci".into(), tags: vec!["tag:ci".into()], shared: false };
    assert!(matches!(decide_for(&config, PEER, Ok(tagged)), Decision::Refused(_)));
    let shared =
        Identity { login: Some(LAWRENCE.into()), node: "x".into(), tags: vec![], shared: true };
    assert!(matches!(decide_for(&config, PEER, Ok(shared)), Decision::Refused(_)));
    assert!(matches!(
        decide_for(&config, PEER, Err(anyhow::anyhow!("whois failed"))),
        Decision::Refused(_)
    ));
}

#[test]
fn agents_and_shell_scopes_allow_connect() {
    assert!(!grant::may_connect(&[Scope::Status]));
    assert!(grant::may_connect(&[Scope::Status, Scope::Agents]));
    assert!(grant::may_connect(&[Scope::Status, Scope::Shell]));
}

#[test]
fn granting_needs_an_interactive_terminal_and_an_allowlisted_login() {
    assert!(grant::require_interactive(false, true).is_err());
    assert!(grant::require_interactive(true, false).is_err());
    assert!(grant::require_interactive(true, true).is_ok());
    assert!(grant::confirmed("yes\n"));
    assert!(!grant::confirmed("y\n"));
    assert!(!grant::confirmed(""));
    let text = grant::consent_text(LAWRENCE, &[Scope::Status]);
    assert!(text.contains(LAWRENCE) && text.contains("read-only") && text.contains("revoke"));
    assert!(grant::consent_text(LAWRENCE, &[Scope::Shell]).contains("run any command"));
}

#[test]
fn audit_log_appends_owner_only_lines() {
    let dir = tempfile::tempdir().unwrap();
    audit::append_in(dir.path(), &serde_json::json!({"decision": "refused", "peer": "8.8.8.8"}))
        .unwrap();
    audit::append_in(dir.path(), &serde_json::json!({"decision": "guest", "login": LAWRENCE}))
        .unwrap();
    let path = dir.path().join("audit.jsonl");
    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[1]["login"], LAWRENCE);
    assert!(lines[0]["ts"].as_str().is_some_and(|ts| !ts.is_empty()));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

fn shared_chat(role: super::shares::Role) -> Config {
    let mut config = leo_host(consented(LAWRENCE, &[Scope::Agents]));
    config.shares.push(super::shares::Share {
        surface: 42,
        login: LAWRENCE.into(),
        role,
        shared_at: grant::now_rfc3339(),
        generation: "boot-1".into(),
        session: "acp_a".to_owned(),
    });
    config
}

/// The daemon boot `generation` with the surface showing chat `acp_a` (none for an empty boot).
fn chat(generation: &str) -> super::shares::Chat {
    let session = if generation.is_empty() { "" } else { "acp_a" };
    super::shares::Chat { generation: generation.into(), session: session.into() }
}

fn author() -> serde_json::Value {
    serde_json::json!({"id": format!("tailnet:{LAWRENCE}"), "name": LAWRENCE,
        "login": LAWRENCE, "node": "lawrence-mbp"})
}

#[test]
fn agent_proxy_refuses_every_non_chat_entrypoint() {
    use serde_json::json;
    let config = shared_chat(super::shares::Role::Member);
    for cmd in [
        "send",
        "list-workspaces",
        "subscribe",
        "agent-session-start",
        "agent-session-trust",
        "agent-session-children",
        "agent-session-media",
        "agent-session-proxy-bind",
        "composer_set",
    ] {
        assert_eq!(
            super::agent_proxy::filter(
                &config,
                &author(),
                "boot-1",
                json!({"cmd": cmd, "surface": 42})
            ),
            Err("scope_not_granted")
        );
    }
    assert_eq!(
        super::agent_proxy::filter(
            &config,
            &author(),
            "boot-1",
            json!({"protocol": "cmux.protocol/2", "cmd": "agent-session-attach", "surface": 42})
        ),
        Err("scope_not_granted")
    );
}

#[test]
fn agent_proxy_requires_this_login_and_surface_and_a_live_grant() {
    use serde_json::json;
    let mut config = shared_chat(super::shares::Role::Member);
    for surface in [json!(43), json!("42"), serde_json::Value::Null] {
        assert_eq!(
            super::agent_proxy::filter(
                &config,
                &author(),
                "boot-1",
                json!({"cmd": "agent-session-attach", "surface": surface})
            ),
            Err("agent_session.not_shared")
        );
    }
    config.shares[0].login = LEO.into();
    let frame = json!({"cmd": "agent-session-attach", "surface": 42});
    assert_eq!(
        super::agent_proxy::filter(&config, &author(), "boot-1", frame.clone()),
        Err("agent_session.not_shared")
    );
    config.shares[0].login = LAWRENCE.into();
    assert!(super::agent_proxy::filter(&config, &author(), "boot-1", frame.clone()).is_ok());
    config.grants[0].revoked_at = Some(grant::now_rfc3339());
    assert_eq!(
        super::agent_proxy::filter(&config, &author(), "boot-1", frame),
        Err("scope_not_granted")
    );
}

#[test]
fn agent_proxy_guests_only_observe_events_and_detach() {
    use serde_json::json;
    let config = shared_chat(super::shares::Role::Guest);
    for cmd in ["agent-session-observe", "agent-session-events", "agent-session-detach"] {
        assert!(
            super::agent_proxy::filter(
                &config,
                &author(),
                "boot-1",
                json!({"cmd": cmd, "surface": 42})
            )
            .is_ok()
        );
    }
    for cmd in [
        "agent-session-attach",
        "agent-session-prompt",
        "agent-session-cancel",
        "agent-session-permission",
    ] {
        assert_eq!(
            super::agent_proxy::filter(
                &config,
                &author(),
                "boot-1",
                json!({"cmd": cmd, "surface": 42})
            ),
            Err("scope_not_granted")
        );
    }
}

#[test]
fn agent_proxy_strips_client_authorship_and_stamps_whois() {
    use serde_json::json;
    let frame = json!({"id": 9, "cmd": "agent-session-prompt", "surface": 42,
        "prompt_id": "p1", "text": "hello", "author": {"login": LEO},
        "_meta": {"acpmux": {"author": {"login": LEO}}}, "_host_author": {"login": LEO},
        "_host_session": "acp_other"});
    let forwarded = super::agent_proxy::filter(
        &shared_chat(super::shares::Role::Member),
        &author(),
        "boot-1",
        frame,
    )
    .unwrap();
    assert_eq!(forwarded["_host_author"], author());
    assert_eq!(forwarded["_host_session"], "acp_a", "the consented chat, not the client's");
    assert!(forwarded.get("author").is_none() && forwarded.get("_meta").is_none());
    assert_eq!(forwarded["id"], 9);
    assert_eq!(forwarded["text"], "hello");
}

#[test]
fn agent_proxy_shares_expire_on_daemon_change() {
    let config = shared_chat(super::shares::Role::Member);
    let frame = serde_json::json!({"cmd":"agent-session-attach", "surface":42});
    assert_eq!(
        super::agent_proxy::filter(&config, &author(), "boot-2", frame),
        Err("agent_session.not_shared")
    );
}

#[test]
fn a_shared_login_on_the_full_access_list_still_goes_through_its_grant() {
    let mut config = leo_host(consented(LAWRENCE, &[Scope::Agents]));
    config.allow = vec![LAWRENCE.to_owned()];
    assert!(matches!(decide_for(&config, PEER, person(LAWRENCE)), Decision::Allowed(_)));
    config.shares = vec![super::shares::Share {
        surface: 7,
        login: LAWRENCE.to_owned(),
        role: super::shares::Role::Member,
        shared_at: "2026-10-26T09:00:00Z".to_owned(),
        generation: "g1".to_owned(),
        session: "acp_a".to_owned(),
    }];
    match decide_for(&config, PEER, person(LAWRENCE)) {
        Decision::Guest(_, scopes) => assert_eq!(scopes, vec![Scope::Agents]),
        other => panic!("expected the scoped grant, got {other:?}"),
    }
    config.grants.clear();
    assert!(matches!(decide_for(&config, PEER, person(LAWRENCE)), Decision::Refused(_)));
}

/// `cmux host allow` is refused while the login has a share, of this boot or a stale one: the
/// share would route it through its grant, so full access would silently not apply. Unsharing
/// (always allowed, whatever the boot) clears the way, and the order the other way is refused too.
#[test]
fn full_access_is_refused_while_the_login_has_a_share() {
    use super::shares::{Role, allowable, applied};
    let config = leo_host(consented(LAWRENCE, &[Scope::Agents]));
    assert!(allowable(&config, LAWRENCE).is_ok(), "no share: allow is fine");
    let shared =
        applied("share", config, 7, LAWRENCE, Role::Member, &chat("boot-1"), &chat("boot-1"))
            .unwrap();
    let refused = allowable(&shared, "Lawrence@Manaflow.ai").unwrap_err().to_string();
    assert!(refused.contains("cmux host unshare"), "{refused}");
    // The daemon restarted since: the share is stale, but admission still routes the login by it.
    assert!(allowable(&shared, LAWRENCE).is_err(), "a stale share refuses allow too");
    assert!(allowable(&shared, LEO).is_ok(), "another login is unaffected");
    let unshared =
        applied("unshare", shared, 7, LAWRENCE, Role::Member, &chat(""), &chat("boot-2")).unwrap();
    assert!(unshared.shares.is_empty());
    assert!(allowable(&unshared, LAWRENCE).is_ok());
    // And a login on the full-access list cannot get a share.
    let mut allowed = unshared;
    allowed.allow = vec![LAWRENCE.to_owned()];
    assert!(
        applied("share", allowed, 7, LAWRENCE, Role::Member, &chat("boot-2"), &chat("boot-2"))
            .is_err()
    );
}

#[test]
fn a_shared_login_takes_the_proxy_even_with_shell() {
    use super::serve::proxied;
    let mut config = leo_host(consented(LAWRENCE, &[Scope::Agents, Scope::Shell]));
    let shell = [Scope::Agents, Scope::Shell];
    assert!(!proxied(&config, Some(LAWRENCE), Some(&shell)), "no share: the full shell grant");
    assert!(proxied(&config, Some(LAWRENCE), Some(&[Scope::Agents])));
    assert!(!proxied(&config, Some(LEO), None), "the owner splices");
    config.shares = vec![super::shares::Share {
        surface: 7,
        login: LAWRENCE.to_owned(),
        role: super::shares::Role::Guest,
        shared_at: "2026-10-26T09:00:00Z".to_owned(),
        generation: "g1".to_owned(),
        session: "acp_a".to_owned(),
    }];
    assert!(proxied(&config, Some(LAWRENCE), Some(&shell)), "a shared guest never splices");
}

#[test]
fn a_member_cannot_answer_the_hosts_asks() {
    let mut config = leo_host(consented(LAWRENCE, &[Scope::Agents]));
    config.shares = vec![super::shares::Share {
        surface: 42,
        login: LAWRENCE.to_owned(),
        role: super::shares::Role::Member,
        shared_at: "2026-10-26T09:00:00Z".to_owned(),
        generation: "boot-1".to_owned(),
        session: "acp_a".to_owned(),
    }];
    let author =
        serde_json::json!({"id": format!("tailnet:{LAWRENCE}"), "login": LAWRENCE, "node": "n"});
    let frame = serde_json::json!({"cmd": "agent-session-permission", "surface": 42,
        "permission_id": "p", "option_id": "allow"});
    assert_eq!(
        super::agent_proxy::filter(&config, &author, "boot-1", frame),
        Err("scope_not_granted")
    );
    let prompt = serde_json::json!({"cmd": "agent-session-prompt", "surface": 42, "text": "hi"});
    assert!(super::agent_proxy::filter(&config, &author, "boot-1", prompt).is_ok());
}

/// A share confirmed at the prompt applies to the config as it is then: a daemon restart while the
/// prompt waited (another boot, so the number may be another chat), a grant revoked meanwhile, or
/// the login put on the full-access list meanwhile each refuse it, and nothing else changes.
#[test]
fn a_confirmed_share_is_refused_when_the_boot_or_the_grant_changed_meanwhile() {
    use super::shares::{Role, applied};
    let config = shared_chat(Role::Guest);
    let restarted = applied(
        "share",
        config.clone(),
        42,
        LAWRENCE,
        Role::Member,
        &chat("boot-1"),
        &chat("boot-2"),
    );
    let message = restarted.unwrap_err().to_string();
    assert_eq!(message, crate::localization::catalog().host_share.restarted);
    let shared = applied(
        "share",
        config.clone(),
        42,
        LAWRENCE,
        Role::Member,
        &chat("boot-1"),
        &chat("boot-1"),
    )
    .expect("the same boot applies");
    assert_eq!(shared.shares.len(), 1, "the share is replaced, not added");
    assert_eq!(shared.shares[0].role, Role::Member);
    assert_eq!(shared.shares[0].generation, "boot-1");
    let mut revoked = config.clone();
    revoked.grants.clear();
    assert!(
        applied("share", revoked, 42, LAWRENCE, Role::Member, &chat("boot-1"), &chat("boot-1"))
            .is_err()
    );
    let mut allowed = config.clone();
    allowed.allow = vec![LAWRENCE.to_owned()];
    assert!(
        applied("share", allowed, 42, LAWRENCE, Role::Member, &chat("boot-1"), &chat("boot-1"))
            .is_err()
    );
    // Unsharing needs no boot and no grant: it only ever narrows.
    let mut gone = config;
    gone.grants.clear();
    let unshared =
        applied("unshare", gone, 42, LAWRENCE, Role::Member, &chat(""), &chat("")).unwrap();
    assert!(unshared.shares.is_empty());
}

/// A share pins the chat it was given for: one recorded without a session (before the pin existed)
/// matches nothing, and the share records the session the prompt named. A rebind of the surface to
/// another chat while the prompt waited refuses the share.
#[test]
fn a_share_is_pinned_to_the_consented_chat() {
    use super::shares::{Chat, Role, applied};
    let mut config = shared_chat(Role::Member);
    config.shares[0].session.clear();
    let frame = serde_json::json!({"cmd": "agent-session-attach", "surface": 42});
    assert_eq!(
        super::agent_proxy::filter(&config, &author(), "boot-1", frame.clone()),
        Err("agent_session.not_shared"),
        "an unpinned share is not a share"
    );
    let shared =
        applied("share", config, 42, LAWRENCE, Role::Member, &chat("boot-1"), &chat("boot-1"))
            .unwrap();
    assert_eq!(shared.shares[0].session, "acp_a");
    let forwarded = super::agent_proxy::filter(&shared, &author(), "boot-1", frame).unwrap();
    assert_eq!(forwarded["_host_session"], "acp_a");
    let rebound = Chat { generation: "boot-1".into(), session: "acp_b".into() };
    let refused =
        applied("share", shared.clone(), 42, LAWRENCE, Role::Member, &chat("boot-1"), &rebound);
    assert!(refused.is_err(), "the surface changed chats while the prompt waited");
    let none = Chat { generation: "boot-1".into(), session: String::new() };
    assert!(applied("share", shared, 42, LAWRENCE, Role::Member, &none, &none).is_err());
}

#[test]
fn every_access_change_restarts_the_listener_and_the_new_grant_applies() {
    use super::config::{Listener, restarts};
    // A connection keeps what it was admitted with (a raw splice for shell, the filtered proxy for
    // agents, an allow login's full access) until the listener closes it, so each verb's change
    // restarts a running listener.
    for (before, after) in [
        (&[Scope::Shell][..], &[Scope::Agents][..]),
        (&[Scope::Shell][..], &[Scope::Status][..]),
        (&[Scope::Agents][..], &[Scope::Status][..]),
        (&[Scope::Agents][..], &[Scope::Agents, Scope::Shell][..]),
        (&[Scope::Agents][..], &[Scope::Agents][..]),
    ] {
        let old = leo_host(consented(LAWRENCE, before));
        let mut new = old.clone();
        grant::replace(&mut new, "Lawrence@Manaflow.ai", after.to_vec());
        assert!(restarts(&old, &new, Listener::RestartIfChanged), "{before:?} -> {after:?}");
        assert_eq!(new.grants.len(), 1, "the old grant is replaced, never kept beside it");
        match decide_for(&new, PEER, person(LAWRENCE)) {
            Decision::Guest(_, scopes) => assert_eq!(scopes, after.to_vec()),
            other => panic!("expected guest, got {other:?}"),
        }
    }
    let host = leo_host(consented(LAWRENCE, &[Scope::Agents]));
    let mut revoked = host.clone();
    revoked.grants[0].revoked_at = Some("2026-10-20T10:00:00Z".to_owned());
    let mut denied = host.clone();
    denied.allow.push(LAWRENCE.to_owned());
    let mut unshared = host.clone();
    unshared.shares.push(super::shares::Share {
        surface: 7,
        login: LAWRENCE.to_owned(),
        role: super::shares::Role::Member,
        shared_at: "now".to_owned(),
        generation: "boot-1".to_owned(),
        session: "acp_a".to_owned(),
    });
    for changed in [&revoked, &denied, &unshared] {
        assert!(restarts(&host, changed, Listener::RestartIfChanged));
        assert!(restarts(changed, &host, Listener::RestartIfChanged));
    }
    // Nothing changed: nothing to close. `enable` and `disable` handle the listener themselves.
    assert!(!restarts(&host, &host.clone(), Listener::RestartIfChanged));
    assert!(!restarts(&host, &revoked, Listener::Caller));
}

/// Every remote_host source file but config.rs, as the compiler sees it.
const SOURCES: &[(&str, &str)] = &[
    ("admit.rs", include_str!("admit.rs")),
    ("agent_proxy.rs", include_str!("agent_proxy.rs")),
    ("audit.rs", include_str!("audit.rs")),
    ("client.rs", include_str!("client.rs")),
    ("grant.rs", include_str!("grant.rs")),
    ("mod.rs", include_str!("mod.rs")),
    ("preface.rs", include_str!("preface.rs")),
    ("serve.rs", include_str!("serve.rs")),
    ("service.rs", include_str!("service.rs")),
    ("shares.rs", include_str!("shares.rs")),
];

/// What in a source file writes or restarts around the config outside `config::commit`: naming
/// the file (a hand-written write), calling the old save, or taking `Listener::Caller` (the verb
/// handles the listener itself).
fn bypasses(source: &str) -> Vec<&'static str> {
    [
        ("\"remote.json\"", "names remote.json"),
        ("config::save", "calls config::save"),
        ("Listener::Caller", "handles the listener itself"),
    ]
    .into_iter()
    .filter(|(needle, _)| source.contains(needle))
    .map(|(_, what)| what)
    .collect()
}

#[test]
fn every_config_write_goes_through_commit() {
    // `config::save` is private, so a new verb cannot call it. This also refuses a verb that
    // writes remote.json by hand, and a `Listener::Caller` outside enable and disable.
    for (name, source) in SOURCES {
        let found = bypasses(source);
        if *name == "mod.rs" {
            assert_eq!(found, ["handles the listener itself"], "mod.rs");
            assert_eq!(source.matches("Listener::Caller").count(), 2, "only enable and disable");
        } else {
            assert!(found.is_empty(), "{name}: {found:?}; write the config through config::commit");
        }
    }
    // A new verb that writes the config without the path is caught.
    let new_verb = r#"fn pause(args: &[String]) -> anyhow::Result<()> {
        let mut config = config::load()?;
        config.enabled = false;
        std::fs::write(config::dir()?.join("remote.json"), serde_json::to_vec(&config)?)?;
        Ok(())
    }"#;
    assert_eq!(bypasses(new_verb), ["names remote.json"]);
    let skips_restart = "config::commit(&before, &config, &lock, config::Listener::Caller)?;";
    assert_eq!(bypasses(skips_restart), ["handles the listener itself"]);
}
