//! Access requests: a signed-in account with no access asks the owner, who approves it with a
//! role or declines it.
use super::*;

fn scratch(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("cmux-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

fn terms() -> ShareTerms {
    ShareTerms { ttl_secs: 3600, uses: 1, create_id: None, role: None, signed_in_role: None }
}

fn made(shares: &LinkShares, dir: Option<&Path>) -> String {
    let created = shares.insert(dir, "acp_x".into(), 1, terms(), false).unwrap();
    created["share_id"].as_str().unwrap().to_owned()
}

fn ask(share_id: &str, account: Option<&str>) -> AccessAsk {
    AccessAsk {
        share_id: share_id.into(),
        account: account.map(str::to_owned),
        name: "Sam Park".into(),
        avatar_url: Some("https://lh3.example.com/a/sam.png".into()),
    }
}

fn pending(shares: &LinkShares, dir: Option<&Path>) -> Value {
    let all = shares.with(dir, |all, now| Ok((all[0].shown(now), false))).unwrap();
    all["requests"].clone()
}

fn redeem(share_id: &str, account: &str, attempt: &str) -> Redeem {
    Redeem {
        share_id: share_id.into(),
        secret: String::new(),
        name: "Sam".into(),
        attempt_id: attempt.into(),
        account: Some(account.into()),
        avatar_url: None,
    }
}

fn approve(share_id: &str, account: &str, role: Option<Role>) -> Approve {
    Approve { share_id: share_id.into(), account: account.into(), role }
}

fn account_of(share_id: &str, account: &str) -> Uninvite {
    Uninvite { share_id: share_id.into(), account: account.into() }
}

#[test]
fn a_new_request_is_recorded_pending_and_a_repeat_changes_nothing() {
    let directory = scratch("requests-new");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    let answer = shares.request_access(dir, ask(&id, Some(" Sam@Example.com "))).unwrap();
    assert_eq!(answer, json!({"share_id": id, "account": "sam@example.com", "state": "requested"}));
    let shown = pending(&shares, dir);
    assert_eq!(shown.as_array().unwrap().len(), 1, "{shown}");
    assert_eq!(shown[0]["account"], "sam@example.com");
    assert_eq!(shown[0]["name"], "Sam Park");
    assert_eq!(shown[0]["state"], "pending");
    assert_eq!(shown[0]["avatar_url"], "https://lh3.example.com/a/sam.png");
    let first = shown[0]["requested_at"].clone();
    shares.advance(Duration::from_secs(5));
    assert!(shares.request_access(dir, ask(&id, Some("sam@example.com"))).is_ok());
    let again = pending(&shares, dir);
    assert_eq!(again.as_array().unwrap().len(), 1, "one per account");
    assert_eq!(again[0]["requested_at"], first, "a repeat keeps the first ask");
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn an_anonymous_visitor_a_bad_name_and_an_unknown_share_cannot_request() {
    let directory = scratch("requests-refused");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    assert_eq!(shares.request_access(dir, ask(&id, None)).unwrap_err(), "share.needs_sign_in");
    let mut bad = ask(&id, Some("sam@example.com"));
    bad.name = String::new();
    assert_eq!(shares.request_access(dir, bad).unwrap_err(), "share.name");
    assert_eq!(
        shares.request_access(dir, ask("nope", Some("sam@example.com"))).unwrap_err(),
        "share.unknown"
    );
    assert_eq!(
        shares.request_access(dir, ask(&id, Some("two words"))).unwrap_err(),
        "share.bad_request"
    );
    assert_eq!(pending(&shares, dir), json!([]));
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn an_invited_account_is_told_so_and_a_removed_one_is_kicked() {
    let directory = scratch("requests-invited");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    shares
        .invite(
            dir,
            &Invite { share_id: id.clone(), account: "ann@example.com".into(), role: None },
        )
        .unwrap();
    assert_eq!(
        shares.request_access(dir, ask(&id, Some("ann@example.com"))).unwrap_err(),
        "share.invited"
    );
    shares.uninvite(dir, &account_of(&id, "ann@example.com")).unwrap();
    assert_eq!(
        shares.request_access(dir, ask(&id, Some("ann@example.com"))).unwrap_err(),
        "share.kicked"
    );
    assert_eq!(pending(&shares, dir), json!([]));
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn a_declined_account_asking_again_gets_the_pending_answer_and_stays_hidden() {
    let directory = scratch("requests-declined");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    let first = shares.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap();
    shares.decline_request(dir, &account_of(&id, "sam@example.com")).unwrap();
    assert_eq!(pending(&shares, dir), json!([]), "a declined request is not listed");
    let again = shares.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap();
    assert_eq!(again, first, "the same answer as a pending request's");
    assert_eq!(pending(&shares, dir), json!([]), "asking again does not make it pending");
    // It cannot approve what is declined, and declining twice changes nothing.
    assert_eq!(
        shares.approve_request(dir, &approve(&id, "sam@example.com", None)).unwrap_err(),
        "share.unknown"
    );
    assert!(shares.decline_request(dir, &account_of(&id, "sam@example.com")).is_ok());
    assert_eq!(
        shares.decline_request(dir, &account_of(&id, "who@example.com")).unwrap_err(),
        "share.unknown"
    );
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn pending_requests_are_bounded_per_share() {
    let directory = scratch("requests-limit");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    for i in 0..MAX_REQUESTS {
        shares.request_access(dir, ask(&id, Some(&format!("u{i}@example.com")))).unwrap();
    }
    assert_eq!(
        shares.request_access(dir, ask(&id, Some("late@example.com"))).unwrap_err(),
        "share.limit"
    );
    // A repeat of one already there still answers.
    assert!(shares.request_access(dir, ask(&id, Some("u0@example.com"))).is_ok());
    // Declining one makes room for a pending one, until the records (declined too) run out.
    shares.decline_request(dir, &account_of(&id, "u0@example.com")).unwrap();
    assert!(shares.request_access(dir, ask(&id, Some("late@example.com"))).is_ok());
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn an_ended_share_takes_no_request_and_drops_the_ones_it_had() {
    let directory = scratch("requests-ended");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    shares.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap();
    shares.end(dir, &Named { share_id: id.clone(), guest_id: None }).unwrap();
    assert_eq!(
        shares.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap_err(),
        "share.revoked"
    );
    let kept = shares.with(dir, |all, _| Ok((all[0].requests.len(), false))).unwrap();
    assert_eq!(kept, 0, "the share's end dropped its requests");
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn approving_invites_the_account_with_the_role_and_it_then_redeems() {
    for (role, expected) in [(None, "view"), (Some(Role::View), "view"), (Some(Role::Talk), "talk")]
    {
        let directory = scratch(&format!("requests-approve-{expected}-{}", role.is_some()));
        let dir = Some(directory.as_path());
        let shares = LinkShares::default();
        let id = made(&shares, dir);
        assert_eq!(
            shares.redeem(dir, redeem(&id, "sam@example.com", "a0")).unwrap_err(),
            "share.not_invited"
        );
        shares.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap();
        let answer = shares.approve_request(dir, &approve(&id, "Sam@example.com", role)).unwrap();
        assert_eq!(
            (&answer["account"], &answer["role"]),
            (&json!("sam@example.com"), &json!(expected))
        );
        assert_eq!(pending(&shares, dir), json!([]), "the request is gone");
        let joined = shares.redeem(dir, redeem(&id, "sam@example.com", "a1")).unwrap();
        assert_eq!(joined["role"], expected);
        // Approving again: nothing pending any more.
        assert_eq!(
            shares.approve_request(dir, &approve(&id, "sam@example.com", None)).unwrap_err(),
            "share.unknown"
        );
        let _ = std::fs::remove_dir_all(&directory);
    }
}

#[test]
fn a_direct_invite_clears_the_accounts_request() {
    let directory = scratch("requests-direct-invite");
    let dir = Some(directory.as_path());
    let shares = LinkShares::default();
    let id = made(&shares, dir);
    shares.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap();
    shares
        .invite(dir, &Invite { share_id: id, account: "sam@example.com".into(), role: None })
        .unwrap();
    assert_eq!(pending(&shares, dir), json!([]));
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn requests_survive_a_restart_and_an_old_file_without_them_loads() {
    let old = json!([{"share_id":"s1", "session":SESSION_NAME, "surface":1, "created_at":0,
        "expires_at":u64::MAX, "uses_left":1, "state":"active", "secret_sha256":"00",
        "guests":[]}]);
    let shares: Vec<LinkShare> = serde_json::from_value(old).unwrap();
    assert!(shares[0].requests.is_empty());
    // An empty list is not written, so an older daemon reads the file as before.
    assert!(!serde_json::to_string(&shares).unwrap().contains("requests"));
    assert_eq!(shares[0].shown(0)["requests"], json!([]));

    let directory = scratch("requests-restart");
    let dir = Some(directory.as_path());
    let registry = LinkShares::default();
    let id = made(&registry, dir);
    registry.request_access(dir, ask(&id, Some("sam@example.com"))).unwrap();
    registry.request_access(dir, ask(&id, Some("eve@example.com"))).unwrap();
    registry.decline_request(dir, &account_of(&id, "eve@example.com")).unwrap();
    let reloaded = LinkShares::default();
    let shown = pending(&reloaded, dir);
    assert_eq!(shown.as_array().unwrap().len(), 1, "{shown}");
    assert_eq!(shown[0]["account"], "sam@example.com");
    // The declined one is remembered across the restart.
    assert!(reloaded.request_access(dir, ask(&id, Some("eve@example.com"))).is_ok());
    assert_eq!(pending(&reloaded, dir).as_array().unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(&directory);
}

const SESSION_NAME: &str = "acp_x";
