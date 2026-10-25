//! A session records the pull requests its `gh pr create` calls opened (their URLs, once each),
//! so the sidebar's session tree counts every pull request a session opened, not only the one
//! of the branch its folder has checked out now.

use super::*;

#[tokio::test]
async fn pull_requests_lists_each_url_gh_pr_create_printed_once() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "prs").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["pullRequests"], json!([]));

    c.request(method::SESSION_PROMPT, prompt(&id, "gh-pr-create", None)).await.unwrap();

    // `gh pr view` printed pull/9: viewed, not opened. pr-3 printed pull/7 again. A grep that
    // mentions gh pr create (pull/10), `gh pr create && gh pr view` (pull/11) and a failed
    // create that named the branch's existing pull request (pull/12) do not count.
    let opened = json!([
        "https://github.com/manaflow-ai/cmux/pull/7",
        "https://github.com/manaflow-ai/cmux-tui/pull/8",
    ]);
    assert_eq!(hub.session_summary(&session)["pullRequests"], opened);
    let meta = serde_json::to_value(session.meta()).unwrap();
    assert_eq!(meta["pullRequests"], opened, "{meta}");
    let list = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    let row = list["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == id.as_str())
        .cloned()
        .unwrap();
    assert_eq!(row["pullRequests"], opened, "{row}");
}
