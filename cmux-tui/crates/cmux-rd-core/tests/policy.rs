//! Access policy tests required by remote-desktop.md section 11.1.

use cmux_rd_core::policy::{Admission, ConsentRule, Deny, Grant, HostPolicy, Mode, Principal, PrincipalClass, admit};
use cmux_rd_core::session::{Actor, EndReason, SessionState, SessionTable};

const NOW: u64 = 1_000_000;

fn person(user: &str, install: &str) -> Principal {
    Principal { user: user.into(), install: install.into(), class: PrincipalClass::User, interactive: true }
}

fn with_class(user: &str, class: PrincipalClass) -> Principal {
    Principal { user: user.into(), install: "i-agent".into(), class, interactive: false }
}

fn policy() -> HostPolicy {
    HostPolicy {
        enabled: true,
        owner_user: "lawrence".into(),
        grants: vec![Grant {
            id: "g-austin".into(),
            user: "austin".into(),
            mode: Mode::Control,
            unattended: false,
            expires_at_ms: Some(NOW + 1_000),
        }],
        consent: ConsentRule::AskOthers,
        unattended_allowed: true,
    }
}

#[test]
fn ops_without_a_hello_principal_are_refused() {
    let mut t = SessionTable::new(policy());
    assert_eq!(t.start("k", None, Mode::View, None, NOW), Err(Deny::NoPrincipal));
    let owner = person("lawrence", "laptop");
    let id = t.start("k1", Some(&owner), Mode::Control, None, NOW).expect("start");
    assert_eq!(t.stop(id, &Actor::Remote(None)), Err(Deny::NoPrincipal));
    assert_eq!(t.set_mode(id, None, Mode::View, None, NOW), Err(Deny::NoPrincipal));
}

#[test]
fn agents_are_refused_control() {
    let p = policy();
    for class in [PrincipalClass::Agent, PrincipalClass::Run] {
        for mode in [Mode::View, Mode::Control] {
            assert_eq!(admit(&p, Some(&with_class("lawrence", class)), mode, None, NOW), Admission::Deny(Deny::AgentClass));
        }
    }
    let mux = with_class("lawrence", PrincipalClass::Mux);
    assert_eq!(admit(&p, Some(&mux), Mode::Control, None, NOW), Admission::Deny(Deny::AgentControl));
    // A mux may open a view-only pane for its own user.
    assert_eq!(admit(&p, Some(&mux), Mode::View, None, NOW), Admission::Allow { needs_consent: false, via_grant: None });
    // Never for another user's host.
    let other_mux = with_class("austin", PrincipalClass::Mux);
    assert_eq!(admit(&p, Some(&other_mux), Mode::View, None, NOW), Admission::Deny(Deny::NoGrant));
    // A mux session cannot be upgraded to control.
    let mut t = SessionTable::new(p);
    let id = t.start("m", Some(&mux), Mode::View, None, NOW).expect("start");
    assert_eq!(t.set_mode(id, Some(&mux), Mode::Control, None, NOW), Err(Deny::AgentControl));
    assert!(!t.may_inject_input(id, &mux));
}

#[test]
fn a_viewer_cannot_stop_or_join_another_viewers_session() {
    let mut t = SessionTable::new(policy());
    let owner = person("lawrence", "laptop");
    let austin = person("austin", "austin-mac");
    let owner_session = t.start("a", Some(&owner), Mode::Control, None, NOW).expect("owner");
    let austin_session = t.start("b", Some(&austin), Mode::View, None, NOW).expect("austin");
    assert_eq!(t.stop(owner_session, &Actor::Remote(Some(austin.clone()))), Err(Deny::NotYourSession));
    assert_eq!(t.set_mode(owner_session, Some(&austin), Mode::View, None, NOW), Err(Deny::NotYourSession));
    // Joining = receiving media or injecting input on a session that is not yours.
    assert!(!t.may_send_media(owner_session, &austin));
    assert!(!t.may_inject_input(owner_session, &austin));
    // The same user from another install is another viewer.
    let owner_phone = person("lawrence", "phone");
    assert!(!t.may_send_media(owner_session, &owner_phone));
    assert_eq!(t.stop(owner_session, &Actor::Remote(Some(owner_phone))), Err(Deny::NotYourSession));
    // Each viewer stops its own session.
    assert_eq!(t.stop(austin_session, &Actor::Remote(Some(austin.clone()))), Ok(()));
    assert_eq!(t.get(owner_session).map(|s| s.state), Some(SessionState::Active));
}

#[test]
fn a_revoked_grant_ends_its_sessions() {
    let mut t = SessionTable::new(policy());
    let austin = person("austin", "austin-mac");
    let owner = person("lawrence", "laptop");
    let a = t.start("a", Some(&austin), Mode::Control, None, NOW).expect("austin");
    let o = t.start("o", Some(&owner), Mode::Control, None, NOW).expect("owner");
    let mut p = policy();
    p.grants.clear();
    t.set_policy(p, NOW);
    assert_eq!(t.get(a).map(|s| s.state), Some(SessionState::Ended(EndReason::GrantRevoked)));
    assert!(!t.may_send_media(a, &austin));
    assert_eq!(t.get(o).map(|s| s.state), Some(SessionState::Active));
    // A new request without the grant is refused.
    assert_eq!(t.start("a2", Some(&austin), Mode::View, None, NOW), Err(Deny::NoGrant));
}

#[test]
fn an_expired_grant_ends_its_sessions_and_refuses_new_ones() {
    let mut t = SessionTable::new(policy());
    let austin = person("austin", "austin-mac");
    let a = t.start("a", Some(&austin), Mode::View, None, NOW).expect("austin");
    t.expire(NOW + 1_000);
    assert_eq!(t.get(a).map(|s| s.state), Some(SessionState::Ended(EndReason::GrantRevoked)));
    assert_eq!(t.start("a2", Some(&austin), Mode::View, None, NOW + 1_000), Err(Deny::GrantExpired));
}

#[test]
fn a_grant_to_another_person_without_expiry_is_not_honored() {
    let mut p = policy();
    p.grants[0].expires_at_ms = None;
    assert_eq!(admit(&p, Some(&person("austin", "x")), Mode::View, None, NOW), Admission::Deny(Deny::GrantExpired));
}

#[test]
fn host_stop_ends_every_session_and_no_media_flows_after_it() {
    let mut t = SessionTable::new(policy());
    let owner = person("lawrence", "laptop");
    let austin = person("austin", "austin-mac");
    let o = t.start("o", Some(&owner), Mode::Control, None, NOW).expect("owner");
    let a = t.start("a", Some(&austin), Mode::View, None, NOW).expect("austin");
    assert!(t.may_send_media(o, &owner) && t.may_send_media(a, &austin));
    t.stop_all();
    assert!(!t.may_send_media(o, &owner));
    assert!(!t.may_send_media(a, &austin));
    assert!(!t.may_inject_input(o, &owner));
    // A viewer cannot revive an ended session.
    assert_eq!(t.set_mode(o, Some(&owner), Mode::Control, None, NOW), Err(Deny::NoSession));
    let ended = t
        .take_audit()
        .into_iter()
        .filter(|e| matches!(e, cmux_rd_core::session::AuditEvent::Ended { reason: EndReason::StoppedByHost, .. }))
        .count();
    assert_eq!(ended, 2);
}

#[test]
fn host_user_stop_wins_over_the_viewer() {
    let mut t = SessionTable::new(policy());
    let austin = person("austin", "austin-mac");
    let a = t.start("a", Some(&austin), Mode::Control, None, NOW).expect("austin");
    assert_eq!(t.stop(a, &Actor::HostUser), Ok(()));
    assert_eq!(t.get(a).map(|s| s.state), Some(SessionState::Ended(EndReason::StoppedByHost)));
}

#[test]
fn hosting_off_refuses_and_ends_everything() {
    let mut t = SessionTable::new(policy());
    let owner = person("lawrence", "laptop");
    let o = t.start("o", Some(&owner), Mode::Control, None, NOW).expect("owner");
    let mut p = policy();
    p.enabled = false;
    t.set_policy(p, NOW);
    assert_eq!(t.get(o).map(|s| s.state), Some(SessionState::Ended(EndReason::HostingDisabled)));
    assert_eq!(t.start("o2", Some(&owner), Mode::View, None, NOW), Err(Deny::HostingDisabled));
}

#[test]
fn consent_is_asked_when_someone_else_is_at_the_console() {
    let mut t = SessionTable::new(policy());
    let owner = person("lawrence", "laptop");
    let id = t.start("o", Some(&owner), Mode::Control, Some("austin"), NOW).expect("start");
    assert_eq!(t.get(id).map(|s| s.state), Some(SessionState::AwaitingConsent));
    assert!(!t.may_send_media(id, &owner));
    // The person at the host allows view only.
    t.consent(id, Some(Mode::View)).expect("consent");
    assert!(t.may_send_media(id, &owner));
    assert!(!t.may_inject_input(id, &owner));
    // A refusal ends a pending request.
    let id2 = t.start("o2", Some(&owner), Mode::View, Some("austin"), NOW).expect("start");
    assert_eq!(t.consent(id2, None), Err(Deny::ConsentDenied));
    assert_eq!(t.get(id2).map(|s| s.state), Some(SessionState::Ended(EndReason::ConsentDenied)));
}

#[test]
fn consent_needed_on_a_headless_host_is_refused_unless_unattended() {
    let mut p = policy();
    p.consent = ConsentRule::AskAlways;
    let owner = person("lawrence", "laptop");
    assert_eq!(admit(&p, Some(&owner), Mode::View, None, NOW), Admission::Deny(Deny::ConsentUnavailable));
    p.grants.push(Grant { id: "g-own".into(), user: "lawrence".into(), mode: Mode::Control, unattended: true, expires_at_ms: None });
    assert_eq!(admit(&p, Some(&owner), Mode::Control, None, NOW), Admission::Allow { needs_consent: false, via_grant: None });
    // Team policy that forbids unattended grants brings the consent step back.
    p.unattended_allowed = false;
    assert_eq!(admit(&p, Some(&owner), Mode::View, None, NOW), Admission::Deny(Deny::ConsentUnavailable));
}

#[test]
fn a_view_grant_does_not_allow_control() {
    let mut p = policy();
    p.grants[0].mode = Mode::View;
    let austin = person("austin", "x");
    assert!(matches!(admit(&p, Some(&austin), Mode::View, None, NOW), Admission::Allow { .. }));
    assert_eq!(admit(&p, Some(&austin), Mode::Control, None, NOW), Admission::Deny(Deny::NoGrant));
}

#[test]
fn start_is_idempotent_per_install_and_key() {
    let mut t = SessionTable::new(policy());
    let owner = person("lawrence", "laptop");
    let first = t.start("same", Some(&owner), Mode::View, None, NOW);
    let again = t.start("same", Some(&owner), Mode::View, None, NOW);
    assert_eq!(first, again);
    let other = t.start("other", Some(&owner), Mode::View, None, NOW);
    assert_ne!(first, other);
}

#[test]
fn asking_for_control_keeps_the_view_running_until_consent() {
    let mut t = SessionTable::new(policy());
    let owner = person("lawrence", "laptop");
    let id = t.start("o", Some(&owner), Mode::View, Some("austin"), NOW).expect("start");
    t.consent(id, Some(Mode::View)).expect("view consent");
    assert_eq!(t.set_mode(id, Some(&owner), Mode::Control, Some("austin"), NOW), Ok(SessionState::Active));
    assert!(t.get(id).is_some_and(|s| s.pending_control));
    assert!(t.may_send_media(id, &owner));
    assert!(!t.may_inject_input(id, &owner));
    t.consent(id, Some(Mode::Control)).expect("control consent");
    assert!(t.may_inject_input(id, &owner));
    // Releasing control needs no consent.
    assert_eq!(t.set_mode(id, Some(&owner), Mode::View, Some("austin"), NOW), Ok(SessionState::Active));
    assert!(!t.may_inject_input(id, &owner));
}
