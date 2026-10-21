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
fn only_the_shell_scope_opens_a_full_daemon_connection() {
    assert!(!grant::may_connect(&[Scope::Status]));
    assert!(!grant::may_connect(&[Scope::Status, Scope::Agents]));
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
