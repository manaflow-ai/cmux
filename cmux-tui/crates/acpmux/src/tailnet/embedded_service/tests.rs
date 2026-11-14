use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[tokio::test]
async fn fence_waits_for_a_reconcile_under_way_and_stops_every_later_one() {
    let temporary = tempfile::tempdir().unwrap();
    let config = cmux_tailnet::NodeConfig::new(temporary.path(), "fence");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "fence");
    controller.set_running_for_test(Arc::clone(&node), "new.example.ts.net");

    // An old listener for a stale name: reconcile stops it, and its drain
    // takes long enough for the fence to arrive in the middle.
    let (old_stop, mut old_stopping) = watch::channel(false);
    let (draining, drain_started) = tokio::sync::oneshot::channel();
    let old_task = tokio::spawn(async move {
        let _ = old_stopping.wait_for(|stopped| *stopped).await;
        let _ = draining.send(());
        tokio::time::sleep(Duration::from_millis(200)).await;
        Ok(())
    });
    let old =
        Active { node: None, name: "old.example.ts.net".into(), stop: old_stop, task: old_task };
    let fenced = Fence::default();
    let (_service_stop, stopping) = watch::channel(false);
    let spawned = Arc::new(AtomicBool::new(false));
    let (new_stop, new_stopping) = watch::channel(false);
    let reconciling = {
        let (controller, fenced, spawned) = (controller.clone(), fenced.clone(), spawned.clone());
        tokio::spawn(async move {
            let mut active = Some(old);
            let spawn = move |node: Arc<Node>, name: String| {
                spawned.store(true, Ordering::Release);
                let task = tokio::spawn(std::future::pending::<anyhow::Result<()>>());
                Active { node: Some(node), name, stop: new_stop, task }
            };
            let acted = reconcile(&controller, &fenced, &mut active, &stopping, spawn).await;
            (acted, active, stopping)
        })
    };
    drain_started.await.unwrap();
    fence(&controller, &fenced).await;
    assert!(
        spawned.load(Ordering::Acquire),
        "the fence must wait for a reconcile already under way, never land inside it"
    );
    let (acted, mut active, stopping) = reconciling.await.unwrap();
    assert!(acted);
    assert!(active.as_ref().is_some_and(|current| current.matches(&node, "new.example.ts.net")));

    // After the fence, reconcile neither stops nor replaces the listener,
    // although the controller now reports the node stopped.
    assert_eq!(controller.snapshot().state, "stopped");
    let acted = reconcile(&controller, &fenced, &mut active, &stopping, |_, _| {
        panic!("no listener starts after the shutdown fence")
    })
    .await;
    assert!(!acted);
    assert!(active.is_some(), "the WebSocket shutdown, not the supervisor, closes it");
    assert!(!*new_stopping.borrow(), "the fenced supervisor sent no stop");
    drop(active);
    release_node(node);
}

#[tokio::test]
async fn fenced_supervision_leaves_the_listener_to_the_websocket_shutdown() {
    let (stop, mut stop_seen) = watch::channel(false);
    let (finish, finished) = tokio::sync::oneshot::channel::<()>();
    let (outcome, ended) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        let stopped_by_supervisor = tokio::select! {
            _ = stop_seen.wait_for(|stopped| *stopped) => true,
            _ = finished => false,
        };
        let _ = outcome.send(stopped_by_supervisor);
        Ok::<(), anyhow::Error>(())
    });
    let mut active = Some(Active { node: None, name: "node.example.ts.net".into(), stop, task });
    let (service_stop, mut stopping) = watch::channel(false);
    {
        let hold = hold_fenced(&mut active, &mut stopping);
        tokio::pin!(hold);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut hold).await.is_err(),
            "a fenced supervisor waits for the WebSocket shutdown to drain the listener"
        );
        finish.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), hold).await.unwrap();
    }
    assert!(!ended.await.unwrap(), "the fenced supervisor must not stop the listener itself");
    assert!(active.is_none());

    // Service::shutdown still ends a fenced wait whose listener never drained.
    let (stop, _listener) = watch::channel(false);
    let task = tokio::spawn(std::future::pending::<anyhow::Result<()>>());
    let mut active = Some(Active { node: None, name: "node.example.ts.net".into(), stop, task });
    service_stop.send_replace(true);
    tokio::time::timeout(Duration::from_secs(1), hold_fenced(&mut active, &mut stopping))
        .await
        .unwrap();
    assert!(active.is_some(), "the caller stops an undrained listener with its bound");
}

#[tokio::test]
async fn tailnet_service_bounds_and_joins_stalled_listener_cleanup() {
    let (dropped, notice) = tokio::sync::oneshot::channel();
    struct OnDrop(Option<tokio::sync::oneshot::Sender<()>>);
    impl Drop for OnDrop {
        fn drop(&mut self) {
            let _ = self.0.take().unwrap().send(());
        }
    }
    let guard = OnDrop(Some(dropped));
    let mut task = tokio::spawn(async move {
        let _guard = guard;
        std::future::pending::<()>().await;
    });
    drain(&mut task, Duration::from_millis(1)).await;
    assert!(task.is_finished());
    assert!(notice.await.is_ok());
}
