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
        deadline_ms: None,
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

/// The review of the lane part at 1ea8bb6: a request held up on a stalled or sleeping link
/// reached the Mac after the machine stopped waiting, and ran.
#[test]
fn the_mac_starts_nothing_the_machine_stopped_waiting_for() {
    let sent = 1_000_000;
    let deadline = Some(deadline_from(sent));
    assert!(check_deadline(deadline, sent).is_ok());
    assert!(check_deadline(deadline, sent + LINK_SLACK.as_millis() as u64).is_ok());
    let e = check_deadline(deadline, sent + LINK_SLACK.as_millis() as u64 + 1).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.expired");
    assert_eq!(check_deadline(None, sent).unwrap_err().code, -32602);
    let far = Some(deadline_from(sent + 2 * LINK_SLACK.as_millis() as u64 + 1));
    assert_eq!(check_deadline(far, sent).unwrap_err().code, -32602);
}
