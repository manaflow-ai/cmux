use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[tokio::test]
async fn revocation_during_owner_approval_prevents_execution() {
    let root = tempfile::tempdir().unwrap();
    let destination = root.path().join("must-not-exist");
    let cfg = HandConfig {
        api: "https://example.com".into(),
        hand: "test".into(),
        key: "test".into(),
        profile: super::super::config::Profile::Mac,
        roots: vec![root.path().to_owned()],
        allow: vec![],
        agent_policy: "ask".into(),
    };
    let agents = Agents::default();
    let ctx = Ctx { cfg: &cfg, agents: &agents, sink: tokio::sync::mpsc::channel(1).0 };
    let granted = AtomicBool::new(true);
    let result = handle_with_consent(
        &ctx,
        "fs.write",
        &json!({"path":destination,"text":"forbidden","_level":"ask"}),
        |_| async {
            tokio::task::yield_now().await;
            granted.store(false, Ordering::SeqCst);
            Ok(true)
        },
        || {
            if granted.load(Ordering::SeqCst) {
                Ok(())
            } else {
                Err(HandError::new("consent_required", "revoked"))
            }
        },
    )
    .await;
    assert_eq!(result.unwrap_err().code, "consent_required");
    assert!(!destination.exists());
}
