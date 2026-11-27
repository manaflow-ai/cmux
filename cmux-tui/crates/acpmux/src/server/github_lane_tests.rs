use super::*;

fn req(action: GithubAction) -> GithubActionParams {
    serde_json::from_value(json!({"action": action, "repo": "o/r"})).unwrap()
}

fn err(reason: &str) -> Result<Value, RpcError> {
    Err(RpcError::internal("x").with_data(json!({"reason": reason})))
}

#[test]
fn only_what_never_ran_or_is_safe_twice_moves_to_the_next_owner() {
    for action in [GithubAction::Read, GithubAction::Token, GithubAction::Comment] {
        let r = req(action);
        assert_eq!(failover(&r, &Ok(json!({}))), Next::Done);
        assert_eq!(failover(&r, &err("github.command_failed")), Next::Done);
        assert_eq!(failover(&r, &Err(RpcError::new(-32040, "no"))), Next::Done);
        // A caller over its own hourly reads is over on every Mac: no other owner is asked.
        assert_eq!(failover(&r, &err("github.budget.caller")), Next::Done);
        for not_run in [
            "client.not_sent",
            "client.busy",
            "github.busy",
            "github.budget.pool",
            "github.budget.pace",
        ] {
            assert_eq!(failover(&r, &err(not_run)), Next::Try, "{action:?} {not_run}");
        }
    }
    for lost in ["client.ended", "client.timeout"] {
        assert_eq!(failover(&req(GithubAction::Read), &err(lost)), Next::Try);
        assert_eq!(failover(&req(GithubAction::Token), &err(lost)), Next::Try);
        for once in [GithubAction::Issue, GithubAction::Comment, GithubAction::DraftPr] {
            assert_eq!(failover(&req(once), &err(lost)), Next::Stop, "{once:?} {lost}");
        }
    }
}

#[test]
fn a_github_refusal_counts_as_progress_and_a_lost_answer_does_not() {
    assert_eq!(outcome(&err("github.command_failed")), Outcome::Answered);
    assert_eq!(outcome(&err("github.expired")), Outcome::Answered);
    assert_eq!(outcome(&err("client.timeout")), Outcome::Lost);
    assert_eq!(outcome(&err("github.busy")), Outcome::NotRun);
}
