use super::*;

fn req(action: GithubAction) -> GithubActionParams {
    GithubActionParams {
        session_id: None,
        action,
        repo: "o/r".into(),
        branch: None,
        base: None,
        issue: None,
        title: None,
        body: None,
    }
}

#[test]
fn each_action_takes_exactly_its_own_fields() {
    let mut r = req(GithubAction::Comment);
    assert!(validate(&r).is_err(), "a comment needs its issue and body");
    r.issue = Some(7);
    r.body = Some("hi".into());
    assert!(validate(&r).is_ok());
    r.title = Some("x".into());
    assert!(validate(&r).is_err(), "a comment has no title");

    let mut r = req(GithubAction::Read);
    r.body = Some("x".into());
    assert!(validate(&r).is_err());
}

#[test]
fn names_that_could_carry_more_than_a_name_are_refused() {
    for repo in ["o", "o/r/x", "../r", "o/..", "o/r;rm", "-o/r", "o r/x"] {
        let mut r = req(GithubAction::Read);
        r.repo = repo.into();
        assert!(validate(&r).is_err(), "{repo}");
    }
    let mut r = req(GithubAction::DraftPr);
    r.title = Some("t".into());
    // `owner:branch` is a fork's branch; the rest are not branch names git takes.
    for branch in ["fork:main", "-f", "a..b", "a b", "a\u{1b}[2J", "x.lock", "a@{1}", "/a", "a~1"] {
        r.branch = Some(branch.into());
        assert!(validate(&r).is_err(), "{branch}");
    }
    r.branch = Some("agent/fix-1".into());
    assert!(validate(&r).is_ok());
    r.session_id = Some("has\na newline".into());
    assert!(validate(&r).is_err());
}

#[test]
fn every_action_is_one_fixed_gh_command() {
    let mut pr = req(GithubAction::DraftPr);
    pr.branch = Some("agent/x".into());
    pr.title = Some("--repo=evil/x".into());
    assert_eq!(
        gh_args(&pr),
        [
            "pr",
            "create",
            "--draft",
            "--head=agent/x",
            "--title=--repo=evil/x",
            "--body=",
            "--repo=o/r"
        ]
    );
    let mut view = req(GithubAction::Read);
    assert_eq!(gh_args(&view)[..3], ["repo", "view", "o/r"]);
    view.issue = Some(3);
    assert_eq!(gh_args(&view)[..3], ["pr", "view", "3"]);
    assert_eq!(gh_args(&view).last().unwrap(), "--repo=o/r");
}

#[test]
fn a_record_holds_no_title_body_or_output() {
    let mut r = req(GithubAction::Issue);
    r.title = Some("secret title".into());
    r.body = Some("secret body".into());
    let row = audit_payload(&r, "allowed", None).to_string();
    assert!(!row.contains("secret"), "{row}");
}

#[test]
fn output_limit_never_splits_utf8() {
    let out = clean_output("é".repeat(OUTPUT_MAX).as_bytes());
    assert!(out.ends_with('…'));
    assert!(out.len() <= OUTPUT_MAX + '…'.len_utf8());
}

#[tokio::test]
async fn the_mac_lends_nothing_to_a_peer_it_is_off_for() {
    let slots = Arc::new(tokio::sync::Semaphore::new(1));
    let e = admit_owner("box", false, &slots).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.denied");
    let held = admit_owner("box", true, &slots).unwrap();
    let e = admit_owner("box", true, &slots).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.busy");
    drop(held);
    // Whatever the peer sends is checked again on the Mac.
    let e = serve_owner("box", json!({"action": "merge", "repo": "o/r"})).await.unwrap_err();
    assert_eq!(e.code, -32602);
    let e = serve_owner("box", json!({"action": "read", "repo": "o/r", "token": "x"}))
        .await
        .unwrap_err();
    assert_eq!(e.code, -32602, "an unknown field is refused, not ignored");
}

/// Review of #24797 at c43d357: every kind of GitHub token, whole or cut off, at a word start.
#[test]
fn every_github_token_is_cut_out_whole_or_cut_off() {
    let text = "a ghp_x1 b gho_y2. c ghu_z ghs_w ghr_v github_pat_11A_b2 cut ghs_ab";
    let want =
        "a [redacted] b [redacted]. c [redacted] [redacted] [redacted] [redacted] cut [redacted]";
    assert_eq!(redact_github_tokens(text), want);
    assert_eq!(redact_github_tokens("xghp_kept é ok"), "xghp_kept é ok");
    assert_eq!(redact_github_tokens("(ghp_q)…"), "([redacted])…");
}

/// Review of the broker core at 939021a: `gh` took the daemon's env whole, so a token or a
/// `GH_HOST` there was used instead of the Mac's keyring login on github.com.
#[test]
fn the_gh_the_broker_runs_gets_no_token_or_host_from_the_daemon() {
    let mut gh = std::process::Command::new("gh");
    login_env(&mut gh, None);
    let envs: std::collections::HashMap<_, _> = gh.get_envs().collect();
    let removed = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
    for k in removed.into_iter().chain(["GH_DEBUG", "DEBUG"]) {
        assert_eq!(envs.get(std::ffi::OsStr::new(k)), Some(&None), "{k}");
    }
    assert_eq!(envs.get(std::ffi::OsStr::new("GH_HOST")), Some(&Some("github.com".as_ref())));
}

/// Review of the broker core at c0d5122: the output was cut to its limit before tokens were cut
/// out, and `[redacted]` is longer than the shortest token, so it grew past the limit.
#[test]
fn output_full_of_tokens_stays_within_its_limit() {
    let out = clean_output("ghp_a ".repeat(OUTPUT_MAX).as_bytes());
    assert!(out.len() <= OUTPUT_MAX + '…'.len_utf8(), "{}", out.len());
    assert!(!out.contains("ghp_"), "no token is left");
}
