//! The cmux account calls against a fake backend: account deletion's every reading, the
//! recovery posts, and the team list with roles.

mod fake;

use std::time::Duration;

use cmux_stack_auth::{
    AccountDeletionError, AccountDeletionResult, CmuxApi, CmuxApiConfig, RecoveryError, Session,
    TeamError, TeamPermissions, TeamRole,
};
use fake::{Reply, closed_origin, ok, serve, status};
use serde_json::json;

fn api(origin: &str) -> CmuxApi {
    CmuxApi::new(CmuxApiConfig::new(&format!("{origin}/"))).unwrap()
}

async fn delete_with(
    reply: impl Fn() -> Reply + Send + Sync + 'static,
) -> Result<AccountDeletionResult, AccountDeletionError> {
    let (origin, _) = serve(move |_| reply());
    api(&origin).delete_account("access", "refresh").await
}

#[tokio::test]
async fn account_deletion_sends_the_pair_and_reads_success() {
    let (origin, log) = serve(|_| ok(json!({ "ok": true })));
    assert_eq!(
        api(&origin).delete_account("access", "refresh").await,
        Ok(AccountDeletionResult::Completed)
    );
    let log = log.lock().unwrap();
    assert_eq!((log[0].method.as_str(), log[0].target.as_str()), ("DELETE", "/api/account"));
    assert_eq!(log[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(log[0].header("x-stack-refresh-token").as_deref(), Some("refresh"));
}

#[tokio::test]
async fn account_deletion_reads_every_answer() {
    assert_eq!(
        delete_with(|| ok(json!({ "cleanupIncomplete": true }))).await,
        Ok(AccountDeletionResult::CompletedWithIncompleteServerCleanup)
    );
    assert_eq!(
        delete_with(|| Reply::Answer(204, Vec::new(), String::new())).await,
        Ok(AccountDeletionResult::Completed)
    );
    assert_eq!(
        delete_with(|| ok(json!({ "deletionPending": true }))).await,
        Err(AccountDeletionError::CompletionUnknown)
    );
    assert_eq!(
        delete_with(|| status(401, json!({}))).await,
        Err(AccountDeletionError::Unauthorized)
    );
    for code in ["account_delete_retryable", "account_stack_delete_failed_after_data_delete"] {
        assert_eq!(
            delete_with(move || status(500, json!({ "error": code }))).await,
            Err(AccountDeletionError::StackDeleteIncomplete)
        );
    }
    assert_eq!(
        delete_with(|| status(500, json!({ "error": "account_delete_failed" }))).await,
        Err(AccountDeletionError::Rejected { status: 500 })
    );
    assert_eq!(
        delete_with(|| status(502, json!({}))).await,
        Err(AccountDeletionError::CompletionUnknown)
    );
    assert_eq!(
        delete_with(|| status(408, json!({}))).await,
        Err(AccountDeletionError::CompletionUnknown)
    );
    assert_eq!(
        delete_with(|| status(403, json!({}))).await,
        Err(AccountDeletionError::Rejected { status: 403 })
    );
    assert_eq!(delete_with(|| Reply::Drop).await, Err(AccountDeletionError::CompletionUnknown));
}

#[tokio::test]
async fn account_deletion_tells_a_timeout_from_a_local_failure() {
    let (origin, _) = serve(|_| Reply::Stall);
    let mut config = CmuxApiConfig::new(&origin);
    config.request_timeout = Duration::from_millis(300);
    let stalled = CmuxApi::new(config).unwrap().delete_account("a", "r").await;
    assert_eq!(stalled, Err(AccountDeletionError::TimedOut));

    let refused = api(&closed_origin()).delete_account("a", "r").await;
    assert_eq!(refused, Err(AccountDeletionError::LocalTransportFailure));

    let bad = CmuxApi::new(CmuxApiConfig::new("not a url")).unwrap().delete_account("a", "r").await;
    assert_eq!(bad, Err(AccountDeletionError::InvalidApiBaseUrl));
}

#[tokio::test]
async fn recovery_posts_the_trimmed_lowercased_email() {
    let (origin, log) = serve(|_| ok(json!({})));
    let cmux = api(&origin);
    cmux.request_email_verification("  Person@Example.COM \n").await.unwrap();
    cmux.request_billing_recovery("A@B.C").await.unwrap();
    let log = log.lock().unwrap();
    assert_eq!(
        (log[0].method.as_str(), log[0].target.as_str()),
        ("POST", "/api/auth/email-verification")
    );
    assert_eq!(log[0].json(), json!({ "email": "person@example.com" }));
    assert_eq!(log[1].target, "/api/billing/recover");
    assert_eq!(log[1].json(), json!({ "email": "a@b.c" }));
    assert_eq!(log[0].header("authorization"), None);
}

#[tokio::test]
async fn recovery_reads_a_rate_limit_and_any_other_failure() {
    let (origin, _) = serve(|_| status(429, json!({})));
    assert_eq!(
        api(&origin).request_email_verification("a@b.c").await,
        Err(RecoveryError::RateLimited)
    );
    let (origin, _) = serve(|_| status(500, json!({})));
    assert_eq!(
        api(&origin).request_billing_recovery("a@b.c").await,
        Err(RecoveryError::Unavailable)
    );
    let refused = api(&closed_origin()).request_email_verification("a@b.c").await;
    assert_eq!(refused, Err(RecoveryError::Unavailable));
}

#[tokio::test]
async fn the_cmux_team_list_parses_roles_and_permissions() {
    let (origin, log) = serve(|_| {
        ok(json!({
            "teams": [
                { "id": "t1", "displayName": "Acme", "role": "admin",
                  "permissions": { "updateTeam": true, "deleteTeam": true } },
                { "id": "t2", "displayName": "Other", "role": "owner", "profileImageUrl": "https://i" }
            ],
            "selectedTeamId": "t1"
        }))
    });
    let memberships =
        api(&origin).team_memberships(&Session::new(Some("a"), Some("r"))).await.unwrap();
    assert_eq!(memberships.selected_team_id.as_deref(), Some("t1"));
    assert_eq!(memberships.teams[0].role, Some(TeamRole::Admin));
    assert_eq!(
        memberships.teams[0].permissions,
        TeamPermissions { update_team: true, delete_team: true, ..TeamPermissions::default() }
    );
    // A role this client does not know reads as unknown, and missing permissions as none.
    assert_eq!(memberships.teams[1].role, None);
    assert_eq!(memberships.teams[1].permissions, TeamPermissions::default());
    assert_eq!(memberships.teams[1].profile_image_url.as_deref(), Some("https://i"));
    let log = log.lock().unwrap();
    assert_eq!(log[0].target, "/api/teams");
    assert_eq!(log[0].header("authorization").as_deref(), Some("Bearer a"));
    assert_eq!(log[0].header("x-stack-refresh-token").as_deref(), Some("r"));
}

#[tokio::test]
async fn the_cmux_team_list_maps_refusals() {
    let cases = [
        (403, Some("last_admin"), TeamError::Forbidden),
        (409, Some("team_has_active_subscription"), TeamError::SubscriptionActive),
        (401, None, TeamError::SignedOut),
        (404, None, TeamError::NotFound),
        (429, None, TeamError::Unavailable),
    ];
    for (code, error_code, expected) in cases {
        let (origin, _) = serve(move |_| status(code, json!({ "error": { "code": error_code } })));
        let result = api(&origin).team_memberships(&Session::new(Some("a"), Some("r"))).await;
        assert_eq!(result, Err(expected), "{code} {error_code:?}");
    }
    let (origin, log) = serve(|_| ok(json!({})));
    let signed_out = api(&origin).team_memberships(&Session::new(Some("a"), None)).await;
    assert_eq!(signed_out, Err(TeamError::SignedOut));
    assert!(log.lock().unwrap().is_empty());
    let (origin, _) = serve(|_| ok(json!({ "teams": "nope" })));
    let unreadable = api(&origin).team_memberships(&Session::new(Some("a"), Some("r"))).await;
    assert_eq!(unreadable, Err(TeamError::Unavailable));
}
