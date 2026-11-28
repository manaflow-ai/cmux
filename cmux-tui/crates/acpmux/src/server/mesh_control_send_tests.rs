use super::*;

/// A start carries this Mac's answer over whatever its caller put there; its other fields stay.
#[test]
fn a_start_carries_this_macs_answer_not_the_callers() {
    let caller = json!({"cwd": "/w", "_meta": {"acpmux": {"cmuxTools": "on", "harness": "codex"}}});
    let params = start_params(&caller, "off").unwrap();
    assert_eq!(params["_meta"]["acpmux"]["cmuxTools"], "off");
    assert_eq!(params["_meta"]["acpmux"]["harness"], "codex");
    assert_eq!(params["cwd"], "/w");
    assert_eq!(
        start_params(&json!({"cwd": "/w"}), "on").unwrap()["_meta"]["acpmux"]["cmuxTools"],
        "on"
    );
    assert!(start_params(&json!("x"), "on").is_err());
}

fn receipt(state: &str, detail: Option<&str>) -> crate::mesh::Receipt {
    serde_json::from_value(json!({"messageId": "msg_1", "state": state, "detail": detail})).unwrap()
}

/// A start through the hub answers as a peer's start does once the machine there started it,
/// and says why it did not otherwise.
#[test]
fn a_start_through_the_hub_answers_as_a_peers_start() {
    let v = started(receipt("delivered", Some("s-1")), "lane-17", Some("w"), "k").unwrap();
    assert_eq!(v["sessionId"], "s-1");
    assert_eq!(v["peer"], "lane-17");
    assert_eq!(v["via"], "hub");
    assert_eq!(v["_meta"]["acpmux"]["name"], "w");
    assert_eq!(crate::session_identity::routed_id(&v).unwrap(), "lane-17/s-1");
    let refused = started(receipt("refused", Some("no")), "lane-17", None, "k").unwrap_err();
    assert!(refused.message.contains("no"), "{}", refused.message);
    let pending = started(receipt("leased", None), "lane-17", None, "key-1").unwrap_err();
    assert!(pending.message.contains("msg_1"), "{}", pending.message);
}

/// A hub that fails `fails` reads with a 503 `mesh.unavailable`, then answers `then`.
struct Flaky {
    fails: std::sync::atomic::AtomicUsize,
    then: crate::mesh::Receipt,
}

impl crate::mesh::MeshHub for Flaky {
    fn inbox(
        &self,
        _: Duration,
        _: usize,
    ) -> futures::future::BoxFuture<'_, Result<Vec<crate::mesh::InMessage>, HubError>> {
        unreachable!()
    }
    fn ack<'a>(
        &'a self,
        _: &'a str,
        _: &'a crate::mesh::Ack,
    ) -> futures::future::BoxFuture<'a, Result<(), HubError>> {
        unreachable!()
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        unreachable!()
    }
    fn send<'a>(
        &'a self,
        _: &'a crate::mesh::OutMessage,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::Receipt, HubError>> {
        unreachable!()
    }
    fn receipt<'a>(
        &'a self,
        _: &'a str,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::Receipt, HubError>> {
        let left = self.fails.load(std::sync::atomic::Ordering::SeqCst);
        let then = self.then.clone();
        Box::pin(async move {
            if left > 0 {
                self.fails.store(left - 1, std::sync::atomic::Ordering::SeqCst);
                let mut e = HubError::unavailable("mesh hub answered 503");
                e.refused = true;
                e.status = Some(503);
                e.code = Some("mesh.unavailable".into());
                return Err(e);
            }
            Ok(then)
        })
    }
}

/// A start the machine there started reads as started although the hub failed reads first.
/// Before, the first 503 failed the `new` and a caller's retries started duplicates.
#[tokio::test(start_paused = true)]
async fn a_start_rides_out_a_hub_that_fails_to_answer() {
    let hub = Flaky {
        fails: std::sync::atomic::AtomicUsize::new(3),
        then: receipt("delivered", Some("s-1")),
    };
    let until = tokio::time::Instant::now() + START_WAIT;
    let settled = settled(&hub, receipt("leased", None), until).await.unwrap();
    assert_eq!(settled.state, "delivered");
    assert_eq!(settled.detail.as_deref(), Some("s-1"));
    // Out of time, it says the start is pending (with its message id), not unavailable.
    let hub = Flaky {
        fails: std::sync::atomic::AtomicUsize::new(usize::MAX),
        then: receipt("delivered", Some("s-1")),
    };
    let until = tokio::time::Instant::now() + Duration::from_secs(10);
    let settled = settled(&hub, receipt("leased", None), until).await.unwrap();
    let pending = started(settled, "host-a", Some("w"), "k").unwrap_err();
    assert_eq!(pending.data.unwrap()["reason"], "mesh.start_pending");
}

/// A 503 from the hub is retryable, as `mesh_retry::transient` treats it.
#[test]
fn a_hub_503_is_retryable() {
    let mut e = HubError::unavailable("503");
    e.refused = true;
    e.status = Some(503);
    assert_eq!(error(e).data.unwrap()["retryable"], true);
    assert_eq!(error(HubError::refused("no")).data.unwrap()["retryable"], false);
}

/// A named `new` sent again after its start did not settle resends that start's key, so the
/// hub answers with its session; once it settled, the next `new` is a new start.
#[test]
fn a_new_sent_again_resends_its_unsettled_start() {
    let slot = unsettled::Slot::new(Some("caller-a"), "host-a", "worker-unsettled");
    assert_eq!(slot.key(), None);
    let pending = started(receipt("leased", None), "host-a", None, "k").map(|_| json!({}));
    slot.note("new:key-1", &pending);
    assert_eq!(slot.key().as_deref(), Some("new:key-1"));
    let other = unsettled::Slot::new(Some("caller-b"), "host-a", "worker-unsettled");
    assert_eq!(other.key(), None);
    let refused = started(receipt("refused", Some("no")), "host-a", None, "k").map(|_| json!({}));
    slot.note("new:key-1", &refused);
    assert_eq!(slot.key(), None);
    slot.note("new:key-2", &pending);
    slot.note("new:key-2", &Ok(json!({"sessionId": "s-1"})));
    assert_eq!(slot.key(), None);
}
