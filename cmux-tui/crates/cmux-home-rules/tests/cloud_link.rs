//! Parity tests for the cloud link, the lease rules and reply errors
//! (`HomeCloudLink.swift`, `HomeCloudLease.swift`, `CloudReplyError.swift`,
//! `CloudServerChoiceTests.swift`).

use cmux_home_rules::call;
use cmux_home_rules::cloud::lease;
use cmux_home_rules::cloud::link::{
    Cooldown, Effect, Event, FIRST_RETRY_MS, Link, MAX_RETRY_MS, Outcome, SelfHostInfo, Server,
    State, step,
};
use cmux_home_rules::cloud::reply::{Rejection, ReplyError, classify};
use serde_json::{Value, json};

fn hosted(user: &str) -> Link {
    Link {
        has_endpoint: true,
        id: Some("conn-1".into()),
        user_id: Some(user.into()),
        display_name: "Me".into(),
        server: Server::Hosted,
    }
}

fn self_hosted() -> Link {
    Link {
        has_endpoint: true,
        id: Some("conn-1".into()),
        user_id: None,
        display_name: String::new(),
        server: Server::SelfHosted { url: "http://mini.tail1234.ts.net:7320".into() },
    }
}

fn leased(expires_at: u64) -> Outcome {
    Outcome::Leased { subject: "stack-user-1".into(), expires_at }
}

fn kinds(effects: &[Effect]) -> Vec<&'static str> {
    effects
        .iter()
        .map(|e| match e {
            Effect::Rename { .. } => "rename",
            Effect::Configure { .. } => "configure",
            Effect::Sync { .. } => "sync",
            Effect::Renew { .. } => "renew",
            Effect::LeaseRenewed { .. } => "leaseRenewed",
            Effect::ScheduleRetry { .. } => "scheduleRetry",
            Effect::CancelRetry => "cancelRetry",
            Effect::ScheduleCooldown { .. } => "scheduleCooldown",
            Effect::CancelCooldown => "cancelCooldown",
        })
        .collect()
}

/// A link applied and leased until `expires_at`.
fn leased_state(expires_at: u64) -> State {
    let link = hosted("stack-user-1");
    let (s, _) = step(State::default(), Event::Apply { link: link.clone() });
    let (s, _) = step(s, Event::Synced { link, outcome: leased(expires_at) });
    s
}

fn renewed(
    s: State,
    reason: &str,
    answering: Option<u64>,
    outcome: Outcome,
) -> (State, Vec<Effect>) {
    step(
        s,
        Event::Renewed { reason: reason.into(), answering, link: hosted("stack-user-1"), outcome },
    )
}

#[test]
fn apply_leases_then_configures_leased() {
    let link = hosted("stack-user-1");
    let (s, fx) = step(State::default(), Event::Apply { link: link.clone() });
    assert_eq!(kinds(&fx), ["cancelRetry", "cancelCooldown", "sync"]);
    assert_eq!(s.leasing, 1);
    let (s, fx) = step(s, Event::Synced { link, outcome: leased(10) });
    assert_eq!(s.leasing, 0);
    assert_eq!(s.leased_expiry, Some(10));
    match &fx[0] {
        Effect::Configure { identity, leased, .. } => {
            assert!(*leased);
            assert_eq!(identity.as_ref().unwrap().stack_user_id, "stack-user-1");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(kinds(&fx), ["configure", "cancelRetry"]);
}

#[test]
fn same_link_does_nothing_and_a_new_name_only_renames() {
    let s = leased_state(10);
    let (s2, fx) = step(s.clone(), Event::Apply { link: hosted("stack-user-1") });
    assert!(fx.is_empty());
    assert_eq!(s2, s);
    let mut renamed = hosted("stack-user-1");
    renamed.display_name = "New".into();
    let (s3, fx) = step(s, Event::Apply { link: renamed });
    assert_eq!(kinds(&fx), ["rename"]);
    assert_eq!(s3.leased_expiry, Some(10), "a new display name keeps the lease");
}

#[test]
fn self_hosted_rename_keeps_the_lease_and_does_not_rename() {
    let link = self_hosted();
    let (s, _) = step(State::default(), Event::Apply { link: link.clone() });
    let info = SelfHostInfo {
        user_id: "user_ts_abcdefghijklmnopqrst".into(),
        login: "me@example.com".into(),
        display_name: Some("Me on mini".into()),
    };
    let (s, fx) =
        step(s, Event::Synced { link: link.clone(), outcome: Outcome::SelfHosted { info } });
    match &fx[0] {
        Effect::Configure { identity, .. } => {
            let identity = identity.as_ref().unwrap();
            assert_eq!(identity.stack_user_id, "user_ts_abcdefghijklmnopqrst");
            assert_eq!(identity.display_name, "Me on mini");
            assert!(identity.self_hosted);
        }
        other => panic!("{other:?}"),
    }
    // A Stack sign-in changes nothing on a self-hosted server.
    let mut signed_in = link;
    signed_in.user_id = Some("stack-user-1".into());
    let (_, fx) = step(s, Event::Apply { link: signed_in });
    assert!(fx.is_empty());
}

#[test]
fn switching_account_ends_the_previous_first() {
    let s = leased_state(10);
    let (s, fx) = step(s, Event::Apply { link: hosted("stack-user-2") });
    assert_eq!(kinds(&fx), ["configure", "cancelRetry", "cancelCooldown", "sync"]);
    match &fx[0] {
        Effect::Configure { identity, link, .. } => {
            assert!(identity.is_none());
            assert_eq!(link.as_ref().unwrap().user_id.as_deref(), Some("stack-user-1"));
        }
        other => panic!("{other:?}"),
    }
    assert!(s.replaced_expiries.is_empty());
    assert_eq!(s.leased_expiry, None);
}

#[test]
fn switching_to_self_hosted_replaces_the_hosted_lease() {
    let s = leased_state(10);
    let mut link = self_hosted();
    link.user_id = Some("stack-user-1".into());
    let (_, fx) = step(s, Event::Apply { link });
    assert_eq!(kinds(&fx), ["configure", "cancelRetry", "cancelCooldown", "sync"]);
}

#[test]
fn no_endpoint_is_offline() {
    let mut link = hosted("stack-user-1");
    link.has_endpoint = false;
    let (s, fx) = step(State::default(), Event::Apply { link });
    assert_eq!(s.leasing, 0);
    match fx.last().unwrap() {
        Effect::Configure { link, identity, leased, .. } => {
            assert!(link.is_none());
            assert!(identity.is_some());
            assert!(!leased);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn failed_lease_retries_with_doubling_backoff_to_the_cap() {
    let link = hosted("stack-user-1");
    let (s, _) = step(State::default(), Event::Apply { link: link.clone() });
    let (mut s, fx) = step(s, Event::Synced { link, outcome: Outcome::Failed });
    assert_eq!(fx.last(), Some(&Effect::ScheduleRetry { after_ms: 1_000 }));
    let mut waits = vec![1_000];
    for _ in 0..8 {
        let (s2, fx) = step(s, Event::RetryFired);
        assert_eq!(kinds(&fx), ["renew"]);
        let (s3, fx) = renewed(s2, "missing", None, Outcome::Failed);
        match fx.last() {
            Some(Effect::ScheduleRetry { after_ms }) => waits.push(*after_ms),
            other => panic!("{other:?}"),
        }
        s = s3;
    }
    assert_eq!(
        waits,
        [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, MAX_RETRY_MS, MAX_RETRY_MS, MAX_RETRY_MS]
    );
    // A lease that holds resets it.
    let (s, _) = step(s, Event::RetryFired);
    let (s, fx) = renewed(s, "missing", None, leased(20));
    assert!(kinds(&fx).contains(&"cancelRetry"));
    assert_eq!(s.retry_delay_ms, FIRST_RETRY_MS);
    assert_eq!(s.retry_reason, None);
}

#[test]
fn signed_out_and_superseded_need_no_retry() {
    for outcome in [Outcome::SignedOut, Outcome::Superseded] {
        let link = hosted("stack-user-1");
        let (s, _) = step(State::default(), Event::Apply { link: link.clone() });
        let (s, fx) = step(s, Event::Synced { link, outcome });
        assert!(!kinds(&fx).contains(&"scheduleRetry"));
        assert_eq!(s.retry_reason, None);
    }
}

#[test]
fn session_needed_is_answered_once() {
    let s = leased_state(10);
    let (s, fx) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: Some(10) });
    assert_eq!(kinds(&fx), ["renew"]);
    match &fx[0] {
        Effect::Renew { force_refresh, answering, .. } => {
            assert!(*force_refresh);
            assert_eq!(*answering, Some(10));
        }
        other => panic!("{other:?}"),
    }
    // While lease work runs, another socket's request needs nothing.
    let (s, fx) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: Some(10) });
    assert!(fx.is_empty());
    let (s, fx) = renewed(s, "expired", Some(10), leased(20));
    assert_eq!(kinds(&fx), ["leaseRenewed", "scheduleCooldown", "cancelRetry"]);
    assert_eq!(s.replaced_expiries, [10]);
    // A late request naming the replaced lease needs nothing more.
    let (_, fx) = step(s, Event::SessionNeeded { reason: "missing".into(), expires_at: Some(10) });
    assert!(fx.is_empty());
}

#[test]
fn replaced_expiries_keep_the_newest_eight() {
    let mut s = leased_state(0);
    for exp in 1..=12 {
        let (s2, _) = step(s, Event::LeaseMissing);
        let (s3, _) = renewed(s2, "missing", None, leased(exp));
        s = s3;
    }
    assert_eq!(s.replaced_expiries, (4..=11).collect::<Vec<u64>>());
}

#[test]
fn forced_renewals_wait_for_the_cooldown_which_doubles() {
    let s = leased_state(10);
    let (s, _) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: None });
    let (s, fx) = renewed(s, "expired", None, leased(20));
    assert!(fx.contains(&Effect::ScheduleCooldown { after_ms: 1_000 }));
    assert_eq!(s.forced_wait_ms, 1_000);
    // A forced renewal asked for meanwhile waits.
    let (s, fx) = step(s, Event::SessionNeeded { reason: "expiring".into(), expires_at: None });
    assert!(fx.is_empty());
    assert_eq!(s.pending_forced.as_deref(), Some("expiring"));
    // A missing lease does not wait.
    let (s_missing, fx) =
        step(s.clone(), Event::SessionNeeded { reason: "missing".into(), expires_at: None });
    assert_eq!(kinds(&fx), ["renew"]);
    drop(s_missing);
    // The floor passes with no rest: the pending one goes.
    let (s, fx) = step(s, Event::CooldownFired);
    assert_eq!(kinds(&fx), ["renew"]);
    let (s, fx) = renewed(s, "expiring", None, leased(30));
    assert!(fx.contains(&Effect::ScheduleCooldown { after_ms: 1_000 }));
    assert_eq!(s.forced_wait_ms, 2_000);
    assert_eq!(s.cooldown, Cooldown::Floor { rest_ms: 1_000, proven: false });
    let (s, fx) = step(s, Event::CooldownFired);
    assert_eq!(fx, [Effect::ScheduleCooldown { after_ms: 1_000 }]);
    assert_eq!(s.cooldown, Cooldown::Rest);
    let (s, fx) = step(s, Event::CooldownFired);
    assert!(fx.is_empty());
    assert_eq!(s.cooldown, Cooldown::Idle);
}

#[test]
fn a_proof_in_the_floor_ends_the_cooldown_at_the_floor() {
    let mut s = leased_state(10);
    s.forced_wait_ms = 4_000;
    let (s, _) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: None });
    let (s, _) = renewed(s, "expired", None, leased(20));
    assert_eq!(s.forced_wait_ms, 8_000);
    let (s, _) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: None });
    let (s, fx) = step(s, Event::LeaseProven);
    assert!(fx.is_empty(), "the floor always runs");
    assert_eq!(s.forced_wait_ms, 0);
    let (s, fx) = step(s, Event::CooldownFired);
    assert_eq!(kinds(&fx), ["renew"], "the proof ends it at the floor");
    assert_eq!(s.cooldown, Cooldown::Idle);
}

#[test]
fn a_proof_after_the_floor_cancels_the_rest() {
    let mut s = leased_state(10);
    s.forced_wait_ms = 4_000;
    let (s, _) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: None });
    let (s, _) = renewed(s, "expired", None, leased(20));
    let (s, fx) = step(s, Event::CooldownFired);
    assert_eq!(fx, [Effect::ScheduleCooldown { after_ms: 7_000 }]);
    let (s, _) = step(s, Event::SessionNeeded { reason: "expired".into(), expires_at: None });
    let (_, fx) = step(s, Event::LeaseProven);
    assert_eq!(kinds(&fx), ["cancelCooldown", "renew"]);
}

#[test]
fn lease_missing_waits_for_work_in_flight() {
    let link = hosted("stack-user-1");
    let (s, _) = step(State::default(), Event::Apply { link });
    let (_, fx) = step(s, Event::LeaseMissing);
    assert!(fx.is_empty());
}

#[test]
fn self_hosted_renewal_configures_only_the_link_it_was_for() {
    let link = self_hosted();
    let (s, _) = step(State::default(), Event::Apply { link: link.clone() });
    let (s, _) = step(s, Event::Synced { link: link.clone(), outcome: Outcome::Failed });
    let (s, fx) = step(s, Event::RetryFired);
    assert_eq!(kinds(&fx), ["renew"]);
    let info = SelfHostInfo {
        user_id: "user_ts_x".into(),
        login: "me@example.com".into(),
        display_name: Some(String::new()),
    };
    let (_, fx) = step(
        s.clone(),
        Event::Renewed {
            reason: "missing".into(),
            answering: None,
            link: link.clone(),
            outcome: Outcome::SelfHosted { info: info.clone() },
        },
    );
    match &fx[0] {
        Effect::Configure { identity, .. } => {
            assert_eq!(identity.as_ref().unwrap().display_name, "me@example.com");
        }
        other => panic!("{other:?}"),
    }
    let mut other = link;
    other.id = Some("conn-2".into());
    let (_, fx) = step(
        s,
        Event::Renewed {
            reason: "missing".into(),
            answering: None,
            link: other,
            outcome: Outcome::SelfHosted { info },
        },
    );
    assert_eq!(kinds(&fx), ["cancelRetry"]);
}

#[test]
fn link_step_op_round_trips_json() {
    let reply = call(
        "cloud.link_step",
        &json!({"event": {"kind": "apply", "link": {"hasEndpoint": true, "id": "c", "userId": "u", "displayName": "Me", "server": {"kind": "hosted"}}}}),
    )
    .unwrap();
    assert_eq!(reply["state"]["leasing"], 1);
    assert_eq!(reply["effects"][2]["kind"], "sync");
    assert_eq!(reply["effects"][2]["expectedUserId"], "u");
    let state = reply["state"].clone();
    let reply = call(
        "cloud.link_step",
        &json!({"state": state, "event": {"kind": "synced", "link": {"hasEndpoint": true, "id": "c", "userId": "u", "displayName": "Me"}, "outcome": {"kind": "leased", "subject": "u", "expiresAt": 5}}}),
    )
    .unwrap();
    assert_eq!(reply["state"]["leasedExpiry"], 5);
}

// The lease rules.

fn b64url(bytes: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=chunk.len() {
            out.push(A[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

fn jwt(payload: &Value) -> String {
    format!("eyJhbGciOiJIUzI1NiJ9.{}.sig", b64url(payload.to_string().as_bytes()))
}

const NOW_MS: f64 = 1_800_000_000_000.0;

#[test]
fn an_ipv6_tailnet_origin_keeps_its_brackets() {
    assert_eq!(
        lease::origin("http://[fd7a:115c:a1e0::1]:7320").as_deref(),
        Some("http://[fd7a:115c:a1e0::1]:7320")
    );
    assert_eq!(
        lease::origin("https://cloud-api.cmux.dev").as_deref(),
        Some("https://cloud-api.cmux.dev")
    );
    assert_eq!(
        lease::origin("http://mini.tail1234.ts.net:7320/path?q=1").as_deref(),
        Some("http://mini.tail1234.ts.net:7320")
    );
    assert_eq!(lease::origin("not a url"), None);
    assert_eq!(lease::origin("https://"), None);
}

#[test]
fn claims_read_sub_team_and_exp() {
    let token = jwt(&json!({"sub": "stack-user-1", "team": "team_1", "exp": 1_800_000_600}));
    assert_eq!(lease::subject(&token).as_deref(), Some("stack-user-1"));
    assert_eq!(lease::team(&token).as_deref(), Some("team_1"));
    assert_eq!(lease::expiry(&token, NOW_MS), Some(1_800_000_600_000));
    let empty = jwt(&json!({"sub": "", "team": ""}));
    assert_eq!(lease::subject(&empty), None);
    assert_eq!(lease::team(&empty), None);
    assert_eq!(lease::subject("a.b"), None);
    assert_eq!(lease::subject("a.!!!.c"), None);
}

#[test]
fn an_untrusted_exp_reads_as_missing() {
    let far = jwt(&json!({"exp": 1_800_000_000.0 + 31.0 * 86_400.0}));
    assert_eq!(lease::expiry(&far, NOW_MS), None);
    let edge = jwt(&json!({"exp": 1_800_000_000.0 + 30.0 * 86_400.0}));
    assert!(lease::expiry(&edge, NOW_MS).is_some());
    for bad in [json!(0), json!(-5), json!("1800000600")] {
        assert_eq!(lease::expiry(&jwt(&json!({"exp": bad})), NOW_MS), None);
    }
    assert_eq!(lease::fallback_expiry(NOW_MS), 1_800_000_300_000);
}

#[test]
fn lease_check_refuses_another_account() {
    let token = jwt(&json!({"sub": "stack-user-1", "exp": 1_800_000_600}));
    let ok = call(
        "cloud.lease_check",
        &json!({"token": token, "expectedUserId": "user_stack-user-1", "apiBaseUrl": "https://cloud-api.cmux.dev/v1", "nowMs": NOW_MS}),
    )
    .unwrap();
    assert_eq!(
        ok,
        json!({"kind": "lease", "origin": "https://cloud-api.cmux.dev", "subject": "stack-user-1", "expiresAt": 1_800_000_600_000u64})
    );
    let other = call(
        "cloud.lease_check",
        &json!({"token": token, "expectedUserId": "stack-user-2", "apiBaseUrl": "https://cloud-api.cmux.dev", "nowMs": NOW_MS}),
    )
    .unwrap();
    assert_eq!(other["kind"], "otherAccount");
    let no_exp = jwt(&json!({"sub": "stack-user-1"}));
    let fallback = call(
        "cloud.lease_check",
        &json!({"token": no_exp, "expectedUserId": "stack-user-1", "apiBaseUrl": "https://cloud-api.cmux.dev", "nowMs": NOW_MS}),
    )
    .unwrap();
    assert_eq!(fallback["expiresAt"], 1_800_000_300_000u64);
    let no_origin = call(
        "cloud.lease_check",
        &json!({"token": no_exp, "expectedUserId": "stack-user-1", "apiBaseUrl": "nope", "nowMs": NOW_MS}),
    )
    .unwrap();
    assert_eq!(no_origin["kind"], "noOrigin");
}

#[test]
fn cloud_id_prefixes_once() {
    assert_eq!(lease::cloud_id("stack-user-1"), "user_stack-user-1");
    assert_eq!(lease::cloud_id("user_stack-user-1"), "user_stack-user-1");
    assert_eq!(
        call("cloud.cloud_id", &json!({"stackUserId": "x"})).unwrap(),
        json!({"cloudId": "user_x"})
    );
}

// Reply errors.

fn command(code: &str, message: &str, reason: Option<&str>, retryable: Option<bool>) -> ReplyError {
    ReplyError::Command {
        message: message.into(),
        code: Some(code.into()),
        details: reason.map(|r| json!({"reason": r})),
        retryable,
    }
}

#[test]
fn reply_errors_map_to_rejections() {
    let cases = [
        (
            command("cloud_conversation_rejected", "m", None, Some(true)),
            Rejection::RateLimited { retry_after: None },
        ),
        (
            command("cloud_conversation_rejected", "m", Some("forbidden"), None),
            Rejection::NotAuthorized,
        ),
        (
            command("cloud_conversation_rejected", "m", Some("too_big"), Some(false)),
            Rejection::Invalid { reason: "too_big".into() },
        ),
        (command("cloud_conversation_rejected", "forbidden", None, None), Rejection::NotAuthorized),
        (command("cloud_signed_out", "m", None, None), Rejection::OwnerUnreachable),
        (command("cloud_session_expired", "m", None, None), Rejection::OwnerUnreachable),
        (command("cloud_unauthenticated", "m", None, None), Rejection::OwnerUnreachable),
        (command("cloud_unavailable", "m", None, None), Rejection::Indeterminate),
        (
            command("weird", "the message", None, None),
            Rejection::Invalid { reason: "the message".into() },
        ),
        (ReplyError::NotConnected, Rejection::OwnerUnreachable),
        (ReplyError::MissingCapabilities, Rejection::OwnerUnreachable),
        (ReplyError::Daemon, Rejection::Indeterminate),
        (ReplyError::Other, Rejection::Indeterminate),
        (ReplyError::Rejection { rejection: Rejection::NotAuthorized }, Rejection::NotAuthorized),
    ];
    for (error, want) in cases {
        assert_eq!(classify(&error).rejection, want, "{error:?}");
    }
}

#[test]
fn no_lease_is_signed_out_or_expired() {
    assert!(classify(&command("cloud_signed_out", "", None, None)).is_no_lease);
    assert!(classify(&command("cloud_session_expired", "", None, None)).is_no_lease);
    assert!(!classify(&command("cloud_unauthenticated", "", None, None)).is_no_lease);
    assert!(!classify(&ReplyError::NotConnected).is_no_lease);
    let reply = call(
        "cloud.reply_classify",
        &json!({"error": {"kind": "command", "message": "m", "code": "cloud_conversation_rejected", "details": {"reason": "bad"}}}),
    )
    .unwrap();
    assert_eq!(
        reply,
        json!({"rejection": {"kind": "invalid", "reason": "bad"}, "isNoLease": false, "isFinal": true, "isRetryable": false})
    );
}
