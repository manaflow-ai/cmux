use super::*;
use futures::poll;
#[tokio::test]
async fn queued_update_allows_child_turns_then_excludes_new_turns() {
    let turns = InstallTurns::default();
    let p = turns.program("/opt/bin/codex");
    let parent = p.clone().turn().await;
    let mut install = Box::pin(p.install());
    assert!(poll!(&mut install).is_pending());
    let child = turns.program("codex").turn().await;
    drop(parent);
    assert!(poll!(&mut install).is_pending());
    drop(child);
    let update = install.await;
    let mut next = Box::pin(p.clone().turn());
    assert!(poll!(&mut next).is_pending());
    drop(update);
    next.await;
}
