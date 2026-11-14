use super::*;

#[test]
fn a_lease_takes_only_a_cmux_origin_and_sign_in_and_never_answers_it() {
    let lease = AppLease::default();
    let t = crate::store::now_ms() + 60_000;
    let ok = json!({"seq": 1, "origin": "https://cloud-api.cmux.dev/", "bearer": "b.e.r",
            "team": "team_0123", "expiresAtMs": t + 10});
    let far = crate::store::now_ms() + 2 * SEQ_AHEAD_MAX_MS;
    assert_eq!(lease.set(&ok).unwrap(), json!({"lent": true}));
    assert_eq!(lease.current(|| t + 9).unwrap().1.origin, "https://cloud-api.cmux.dev");
    assert!(lease.current(|| t + 10).is_none(), "an expired sign-in is not used");
    for bad in [
        json!({"seq": 2, "origin": "http://example.com", "bearer": "b", "team": "t", "expiresAtMs": 1}),
        json!({"seq": 2, "origin": "https://evil.example", "bearer": "b", "team": "t", "expiresAtMs": 1}),
        json!({"seq": 2, "origin": "https://cloud-api.cmux.dev.evil.example", "bearer": "b",
                "team": "t", "expiresAtMs": 1}),
        json!({"seq": 2, "origin": "https://cloud-api.cmux.dev/x", "bearer": "b", "team": "t",
                "expiresAtMs": 1}),
        json!({"seq": far, "origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t",
                "expiresAtMs": 1}),
        json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b c", "team": "t", "expiresAtMs": 1}),
        json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t/x", "expiresAtMs": 1}),
        json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t"}),
        json!({"origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t", "expiresAtMs": 1}),
    ] {
        assert_eq!(lease.set(&bad).unwrap_err().code, -32602, "{bad}");
    }
    assert_eq!(lease.set(&json!({"seq": 2, "clear": true})).unwrap(), json!({"lent": false}));
    assert!(lease.current(|| 0).is_none());
}

/// Review of the App token at d8a663b: a lend that reached the daemon after the sign-out
/// that outdated it restored the sign-in, and a late clear could drop the next one's.
#[test]
fn a_lend_or_clear_that_arrives_after_a_newer_one_changes_nothing() {
    let lease = AppLease::default();
    let lend = |seq: u64| {
        json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": u64::MAX})
    };
    // Signed in (1), signed out (2): the lend for 1 arrives last.
    lease.set(&json!({"seq": 2, "clear": true})).unwrap();
    assert_eq!(lease.set(&lend(1)).unwrap(), json!({"lent": false, "stale": true, "seq": 2}));
    assert!(lease.current(|| 0).is_none(), "the sign-out holds");
    // Signed in again (3): the earlier clear arrives after it.
    lease.set(&lend(3)).unwrap();
    assert_eq!(lease.set(&json!({"seq": 2, "clear": true})).unwrap()["stale"], true);
    assert_eq!(lease.current(|| 0).unwrap().1.bearer, "b3", "the newer sign-in holds");
    // A renewal of the same sign-in is taken.
    assert_eq!(lease.set(&lend(3)).unwrap(), json!({"lent": true}));
}

/// Review of the App token at e318f53: a lend at the newest `seq` replaced the sign-in, so a
/// token minted under that `seq` stayed usable for another team, and a cleared or expired
/// sign-in came back under its `seq`.
#[test]
fn a_lend_at_the_newest_seq_only_renews_the_sign_in_held_now() {
    let lease = AppLease::default();
    let lend = |seq: u64, team: &str, expires: u64| {
        json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}{team}"),
                "team": team, "expiresAtMs": expires})
    };
    lease.set(&lend(3, "team_a", u64::MAX)).unwrap();
    assert_eq!(lease.set(&lend(3, "team_b", u64::MAX)).unwrap()["stale"], true);
    assert_eq!(lease.current(|| 0).unwrap().1.team, "team_a", "another team needs a newer seq");
    assert_eq!(lease.set(&lend(4, "team_a", u64::MAX)).unwrap(), json!({"lent": true}));
    assert_eq!(lease.set(&json!({"seq": 4, "clear": true})).unwrap(), json!({"lent": false}));
    assert_eq!(lease.set(&lend(4, "team_a", u64::MAX)).unwrap()["stale"], true);
    assert!(lease.current(|| 0).is_none(), "a cleared sign-in stays cleared at its seq");
    lease.set(&lend(5, "team_a", 1)).unwrap();
    assert_eq!(lease.set(&lend(5, "team_a", u64::MAX)).unwrap()["stale"], true);
    assert!(lease.current(|| 2).is_none(), "an expired one does not come back at its seq");
}

/// Review of the App token at 15a905b: an expired sign-in stayed in memory.
#[test]
fn an_expired_or_replaced_sign_in_is_dropped() {
    let lease = AppLease::default();
    let lend = |seq: u64, expires: u64| {
        json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": expires})
    };
    let t = crate::store::now_ms() + 60_000;
    lease.set(&lend(1, t + 100)).unwrap();
    assert!(lease.current(|| t + 100).is_none());
    assert!(lease.lock().lent.is_none(), "an expired sign-in is dropped from memory");

    lease.set(&lend(2, u64::MAX)).unwrap();
    assert!(lease.still(2, || 0).is_some());
    lease.set(&lend(3, u64::MAX)).unwrap();
    assert!(lease.still(2, || 0).is_none(), "a team switch replaces the sign-in");
    lease.set(&json!({"seq": 4, "clear": true})).unwrap();
    assert!(lease.still(3, || 0).is_none(), "a sign-out ends it");
    lease.set(&lend(5, t + 50)).unwrap();
    assert!(lease.still(5, || t + 49).is_some());
    assert!(lease.still(5, || t + 50).is_none(), "an expired one is not still lent");
}

/// Review of the lease at 0fdead6: a call that came after the sign-in expired answered that
/// one was lent and kept it in memory, and the clock was read before the lock was taken.
#[test]
fn an_expired_sign_in_is_gone_for_every_call_and_the_clock_is_read_under_the_lock() {
    let lease = AppLease::default();
    lease
        .set(&json!({"seq": 5, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
                "team": "team_0", "expiresAtMs": 1}))
        .unwrap();
    let stale = lease.set(&json!({"seq": 4, "clear": true})).unwrap();
    assert_eq!(stale, json!({"lent": false, "stale": true, "seq": 5}));
    assert!(lease.lock().lent.is_none(), "dropped from memory");
    lease
        .set(&json!({"seq": 6, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
                "team": "team_0", "expiresAtMs": u64::MAX}))
        .unwrap();
    let under_lock = || {
        assert!(lease.0.try_lock().is_err(), "the clock is read with the lease locked");
        0
    };
    assert!(lease.still(6, under_lock).is_some());
}

/// Review of the lease at 0bb52d0: a lend that had expired on its way in was kept and
/// answered `lent: true`.
#[test]
fn a_lend_that_expired_on_its_way_moves_seq_on_and_is_not_kept() {
    let lease = AppLease::default();
    let expired = json!({"seq": 7, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
            "team": "team_0", "expiresAtMs": 1});
    assert_eq!(lease.set(&expired).unwrap(), json!({"lent": false}));
    assert!(lease.lock().lent.is_none());
    let older = json!({"seq": 6, "clear": true});
    assert_eq!(lease.set(&older).unwrap()["stale"], true, "its seq still counts");
}

/// Review of the App token at 15a905b: a token minted with a sign-in that was then cleared,
/// replaced or expired was still used.
#[test]
fn a_token_minted_with_a_sign_in_that_changed_is_unused() {
    let lease = AppLease::default();
    let lend = |seq: u64| {
        json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": u64::MAX})
    };
    lease.set(&lend(2)).unwrap();
    let minted = Source::App("ghs_t".into(), 2);
    assert!(while_lent(&minted, Some(&lease), || Ok(())).is_ok());
    assert!(while_lent(&Source::Keyring, None, || Ok(())).is_ok());
    lease.set(&lend(3)).unwrap();
    let e = while_lent(&minted, Some(&lease), || Ok(())).unwrap_err();
    assert_eq!(e.data.unwrap()["code"], "lease_changed", "a team switch while it was minted");
    let minted = Source::App("ghs_t".into(), 3);
    lease.set(&json!({"seq": 4, "clear": true})).unwrap();
    assert!(
        while_lent(&minted, Some(&lease), || Ok(())).is_err(),
        "a sign-out while it was minted"
    );
}

/// Review of the App token at e318f53: the sign-in was checked and let go before `gh`
/// started, so a sign-out between the two still let it start.
#[test]
fn no_sign_out_lands_between_the_check_and_the_start() {
    let lease = std::sync::Arc::new(AppLease::default());
    lease
        .set(&json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
                "team": "team_0", "expiresAtMs": u64::MAX}))
        .unwrap();
    let minted = Source::App("ghs_t".into(), 2);
    let mut sign_out = None;
    let landed = while_lent(&minted, Some(&*lease), || {
        let l = lease.clone();
        let t = std::thread::spawn(move || l.set(&json!({"seq": 3, "clear": true})).unwrap());
        std::thread::sleep(Duration::from_millis(200));
        let landed = t.is_finished();
        sign_out = Some(t);
        Ok(landed)
    });
    assert!(!landed.unwrap(), "the sign-out waits until gh has started");
    sign_out.unwrap().join().unwrap();
    assert!(while_lent(&minted, Some(&*lease), || Ok(())).is_err(), "and then holds");
}

/// Review of the App token at a57885c: Cloud's own words went on to the machine.
#[test]
fn cloud_errors_go_on_in_fixed_words_only() {
    let e = app_error("needs_reauth");
    assert_eq!(
        (e.code, e.data.as_ref().unwrap()["reason"].clone()),
        (-32044, json!("github.not_connected"))
    );
    // Review at d3f3103: a code shaped like the API's own (a token name) went on.
    for odd in ["ghs_secret0123 Bearer x", "ghs_minted0123", "some.other_code"] {
        let e = app_error(odd);
        assert_eq!(e.data.as_ref().unwrap()["code"], "unknown", "{odd}");
        assert!(!e.data.as_ref().unwrap().to_string().contains("ghs_"));
    }
    let odd = app_error("ghs_minted0123");
    assert!(!odd.message.contains("ghs_") && !odd.data.unwrap().to_string().contains("ghs_"));
}

/// Review of the App token at 1f49357: a token broader than asked was used, and a comment
/// asked for pull-request write.
#[test]
fn a_token_with_more_than_its_action_asked_is_refused() {
    let asked = permissions(GithubAction::Comment);
    assert_eq!(asked["pull_requests"], "read", "a comment edits no pull request");
    let ok = json!({"metadata": "read", "issues": "write"});
    assert!(within(Some(&ok), &asked));
    for broad in [
        json!({"metadata": "read", "issues": "write", "contents": "write"}),
        json!({"metadata": "read", "pull_requests": "write"}),
        json!({"issues": "admin"}),
        json!({}),
        json!("all"),
    ] {
        assert!(!within(Some(&broad), &asked), "{broad}");
    }
    assert!(!within(None, &asked));
}

#[test]
fn each_action_asks_the_app_for_its_own_permissions_only() {
    assert_eq!(permissions(GithubAction::Read)["issues"], Value::Null);
    assert_eq!(permissions(GithubAction::Issue)["issues"], "write");
    assert_eq!(permissions(GithubAction::DraftPr)["contents"], "read");
    for a in [GithubAction::Read, GithubAction::Issue, GithubAction::Comment, GithubAction::DraftPr]
    {
        let p = permissions(a);
        assert!(p.get("workflows").is_none() && p.get("actions").is_none(), "{p}");
        assert_ne!(p.get("contents").and_then(Value::as_str), Some("write"), "{p}");
    }
}
