use super::*;

#[cfg(unix)]
#[test]
fn clear_saved_login_rejects_a_symlinked_state_directory() {
    use std::os::unix::fs::symlink;

    let temporary = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    std::fs::write(target.path().join("tailscaled.state"), b"keep me").unwrap();
    let state_dir = temporary.path().join("tailnet");
    symlink(target.path(), &state_dir).unwrap();

    let error = open_logout_directory(&state_dir).unwrap_err();
    assert!(error.contains("private tailnet state directory"), "{error}");
    assert_eq!(std::fs::read(target.path().join("tailscaled.state")).unwrap(), b"keep me");
}

#[test]
fn intentional_logout_close_is_not_reported_as_listener_failure() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "test");
    let node = Arc::new(Node::new(&config).unwrap());
    let controller = Controller::new(temporary.path(), "test");
    controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
    assert!(controller.listener_is_current(&node));
    controller.request_logout();
    assert!(!controller.listener_is_current(&node));
    // Also fence a completion that passed the service check just before logout.
    let runtime =
        tokio::runtime::Builder::new_current_thread().enable_all().build().expect("test runtime");
    runtime.block_on(controller.listener_failed(&node));
    assert!(!controller.retirement_pending());
    assert_eq!(controller.snapshot().state, "stopped");
    assert!(controller.snapshot().error.is_none());
}

#[tokio::test]
async fn shutdown_of_a_watched_node_does_not_report_listener_failure() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "test");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "test");
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.state = LifecycleState::Running(Arc::clone(&node));
        inner.snapshot.state = "running";
    }
    let (closing, release) = block_close(&controller);
    let shutdown = {
        let controller = controller.clone();
        tokio::spawn(async move { controller.shutdown().await })
    };
    closing.await.unwrap();
    // Force the watch's terminal callback while shutdown still owns both
    // gates, before it can clear the node after close returns.
    let closing_node = Arc::clone(&node);
    tokio::task::spawn_blocking(move || closing_node.close().unwrap()).await.unwrap();
    let mut watch_ended = {
        let controller = controller.clone();
        let node = Arc::clone(&node);
        tokio::spawn(async move {
            controller.listener_failed(&node).await;
            release_node(node);
        })
    };
    let returned = tokio::time::timeout(std::time::Duration::from_secs(1), &mut watch_ended).await;
    let before_finish = controller.snapshot();
    let retained = controller.state_node().expect("shutdown owns the node until close finishes");
    assert!(Arc::ptr_eq(&retained, &node));
    release_node(retained);
    release.send(()).unwrap();
    shutdown.await.unwrap().unwrap();
    let immediate = returned.is_ok();
    match returned {
        Ok(result) => result.unwrap(),
        Err(_) => watch_ended.await.unwrap(),
    }
    assert!(immediate, "intentional watch termination must not queue retirement cleanup");
    assert_eq!(before_finish.state, "stopped");
    assert_eq!(controller.snapshot().state, "stopped");
    assert!(controller.snapshot().error.is_none());
    assert!(controller.state_node().is_none());
    assert!(!controller.retirement_pending());
    release_node(node);
}

#[test]
fn tailnet_late_start_failure_cannot_replace_shutdown_state() {
    let temporary = tempfile::tempdir().unwrap();
    let controller = Controller::new(temporary.path(), "test");
    let generation = {
        let mut inner = controller.inner.lock().unwrap();
        inner.state = LifecycleState::Starting;
        inner.generation
    };
    controller.start_failed(generation, "start failed");
    assert_eq!(controller.snapshot().state, "error");
    controller.begin_shutdown();
    controller.start_failed(generation, "late start failed");
    assert_eq!(controller.snapshot().state, "stopped");
}

#[tokio::test]
async fn retirement_waiters_enable_notifications_before_releasing_gates() {
    let notify = tokio::sync::Notify::new();
    let waiting = notify.notified();
    tokio::pin!(waiting);
    waiting.as_mut().enable();
    notify.notify_waiters();
    tokio::time::timeout(std::time::Duration::from_millis(50), waiting)
        .await
        .expect("enabled waiter must observe a notification");
}

#[tokio::test]
async fn tailnet_shutdown_fences_a_queued_start_before_node_creation() {
    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("tailnet");
    let controller = Controller::new(&path, "test");
    let lock = controller.lifecycle.lock().await;
    let queued = controller.clone();
    let start = tokio::spawn(async move { queued.start().await });
    tokio::task::yield_now().await;
    controller.begin_shutdown();
    controller.note_listener_error_if_current(0);
    assert_eq!(controller.snapshot().state, "stopped");
    drop(lock);
    assert!(start.await.unwrap().is_err());
    assert!(controller.node().is_none());
    assert!(!path.exists());
}

#[tokio::test]
async fn tailnet_resume_does_not_create_state_without_opt_in() {
    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("tailnet");
    let controller = Controller::new(&path, "test");
    controller.resume().await.unwrap();
    assert!(controller.node().is_none());
    assert!(!path.exists());
}

#[tokio::test]
async fn tailnet_logout_clears_opt_in_before_any_later_resume() {
    let temporary = tempfile::tempdir().unwrap();
    #[cfg(unix)]
    std::fs::set_permissions(temporary.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    let marker = temporary.path().join("enabled");
    std::fs::write(&marker, b"1\n").unwrap();
    let controller = Controller::new(temporary.path(), "test");
    controller.shutdown().await.unwrap();
    assert!(saved_opt_in(&marker).unwrap());
    controller.logout().await.unwrap();
    assert!(!saved_opt_in(&marker).unwrap());
    controller.resume().await.unwrap();
    assert!(controller.node().is_none());
}

#[tokio::test]
async fn tailnet_resume_rechecks_opt_in_after_waiting_for_lifecycle() {
    let temporary = tempfile::tempdir().unwrap();
    #[cfg(unix)]
    std::fs::set_permissions(temporary.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    let marker = temporary.path().join("enabled");
    std::fs::write(&marker, b"1\n").unwrap();
    let controller = Controller::new(temporary.path(), "test");
    let lock = controller.lifecycle.lock().await;
    let queued = controller.clone();
    let resume = tokio::spawn(async move { queued.resume().await });
    tokio::task::yield_now().await;
    remove_if_present(&marker).unwrap();
    drop(lock);
    resume.await.unwrap().unwrap();
    assert!(controller.node().is_none());
}

#[tokio::test]
async fn failed_explicit_start_keeps_opt_in_for_relaunch_retry() {
    let temporary = tempfile::tempdir().unwrap();
    let path = temporary.path().join("tailnet");
    let marker = path.join("enabled");
    let controller = Controller::new(&path, "test");
    let enabled = marker.clone();
    *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
        assert!(saved_opt_in(&enabled).unwrap(), "intent precedes node startup");
        Err("transient startup failure".into())
    }));
    assert_eq!(controller.start().await.unwrap_err(), "transient startup failure");
    assert_eq!(controller.snapshot().state, "error");
    assert!(controller.state_node().is_none());
    assert!(saved_opt_in(&marker).unwrap());
    controller.shutdown().await.unwrap();

    // A new daemon controller must attempt startup based on persisted
    // intent, even though the first process never had a running node.
    let relaunched = Controller::new(&path, "test");
    let retried = Arc::new(AtomicBool::new(false));
    let attempt = retried.clone();
    *relaunched.node_factory.lock().unwrap() = Some(Box::new(move || {
        attempt.store(true, Ordering::Release);
        Err("retry attempted".into())
    }));
    assert_eq!(relaunched.resume().await.unwrap_err(), "retry attempted");
    assert!(retried.load(Ordering::Acquire));
    assert!(saved_opt_in(&marker).unwrap());
    relaunched.logout().await.unwrap();
    assert!(!saved_opt_in(&marker).unwrap());
    relaunched.resume().await.unwrap();
    assert!(relaunched.state_node().is_none());
}

#[tokio::test]
async fn logout_table_never_starts_a_stopped_or_shutting_down_node() {
    for (name, saved, shutdown) in [
        ("untouched", false, 0),
        ("shutdown-begun", false, 1),
        ("shutdown-finished", false, 2),
        ("saved-stopped", true, 0),
        ("saved-shutdown-begun", true, 1),
        ("saved-shutdown-finished", true, 2),
    ] {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("tailnet");
        if saved {
            std::fs::create_dir(&path).unwrap();
            #[cfg(unix)]
            std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o700))
                .unwrap();
            std::fs::write(path.join("tailscaled.state"), b"saved identity").unwrap();
            std::fs::write(path.join("enabled"), b"1\n").unwrap();
            std::fs::write(path.join("unrelated"), b"keep").unwrap();
        }
        let controller = Controller::new(&path, name);
        *controller.node_factory.lock().unwrap() = Some(Box::new(|| {
            panic!("logout must never invoke node startup");
        }));
        match shutdown {
            1 => controller.begin_shutdown(),
            2 => controller.shutdown().await.unwrap(),
            _ => {}
        }
        let snapshot = controller.logout().await.unwrap();
        assert_eq!(snapshot.state, "stopped", "{name}");
        assert!(controller.state_node().is_none(), "{name}");
        assert!(!path.join("tailscaled.state").exists(), "{name}");
        assert!(!path.join("enabled").exists(), "{name}");
        assert!(controller.node_factory.lock().unwrap().is_some(), "{name}");
        if saved {
            assert_eq!(std::fs::read(path.join("unrelated")).unwrap(), b"keep", "{name}");
            assert_eq!(std::fs::read_dir(&path).unwrap().count(), 1, "{name}");
        } else {
            assert!(!path.exists(), "{name}: logout must not create a state directory");
        }
    }
}

#[tokio::test]
async fn logout_during_shutdown_close_reports_remote_signout_unconfirmed() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "shutdown-logout");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "shutdown-logout");
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.state = LifecycleState::Running(Arc::clone(&node));
        inner.snapshot.state = "running";
    }
    let (closing, release) = block_close(&controller);
    let shutdown_controller = controller.clone();
    let shutdown = tokio::spawn(async move { shutdown_controller.shutdown().await });
    closing.await.expect("shutdown reached node close");
    // Model the request arriving while shutdown owns the close: record the
    // intent synchronously before allowing the blocked close to finish.
    controller.request_logout();
    assert!(matches!(
        &controller.inner.lock().unwrap().state,
        LifecycleState::Retiring { node: Some(_), phase: RetirementPhase::ClosingForLogout }
    ));
    let logout_controller = controller.clone();
    let logout = tokio::spawn(async move { logout_controller.logout().await });
    release.send(()).unwrap();
    shutdown.await.unwrap().expect("shutdown completes");
    let result = logout.await.unwrap();
    assert_eq!(result.unwrap_err(), late_logout_error());
    release_node(node);
}

#[test]
fn shutdown_publishes_stopped_and_clears_identity_atomically() {
    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
    controller.update(|snapshot| {
        snapshot.state = "running";
        snapshot.dns_name = Some("old.example.ts.net".into());
        snapshot.ips = vec!["100.64.0.1".into()];
        snapshot.browse_to_url = Some("https://login.tailscale.com/fake".into());
    });
    let mut changes = controller.subscribe();
    controller.begin_shutdown();
    let published = changes.try_recv().unwrap();
    assert_eq!(published, controller.snapshot());
    assert_eq!(published.state, "stopped");
    assert!(published.dns_name.is_none());
    assert!(published.ips.is_empty());
    assert!(published.browse_to_url.is_none());
    assert!(changes.try_recv().is_err());
}

#[test]
fn failed_logout_still_closes_the_node() {
    let closed = std::cell::Cell::new(false);
    let result = logout_and_close(
        || Err("logout failed".into()),
        || {
            closed.set(true);
            Ok(())
        },
    );
    assert!(closed.get());
    assert_eq!(result, Err("logout failed".into()));
}

fn block_close(
    controller: &Controller,
) -> (tokio::sync::oneshot::Receiver<()>, std::sync::mpsc::Sender<()>) {
    let (entered, notice) = tokio::sync::oneshot::channel();
    let (release, waiting) = std::sync::mpsc::channel();
    *controller.before_close.lock().unwrap() = Some(Box::new(move || {
        let _ = entered.send(());
        waiting.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
    }));
    (notice, release)
}

#[tokio::test]
async fn failed_marker_removal_keeps_the_original_node_until_shutdown_can_finish() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "test");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    // remove_file fails on a directory, exercising the real marker error.
    std::fs::create_dir(temporary.path().join("enabled")).unwrap();
    let controller = Controller::new(temporary.path(), "test");
    controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
    controller.update(|snapshot| {
        snapshot.state = "running";
        snapshot.dns_name = Some("old.example.ts.net".into());
        snapshot.ips = vec!["100.64.0.1".into()];
    });
    let old_generation = controller.inner.lock().unwrap().generation;
    let (closing, release) = block_close(&controller);
    let logout = {
        let c = controller.clone();
        tokio::spawn(async move { c.logout().await })
    };
    closing.await.unwrap();
    let retained = controller.state_node().expect("failed logout retains ownership during close");
    assert!(Arc::ptr_eq(&retained, &node));
    release_node(retained);
    let mut shutdown = {
        let c = controller.clone();
        tokio::spawn(async move { c.shutdown().await })
    };
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(20), &mut shutdown).await.is_err()
    );
    release.send(()).unwrap();
    assert!(logout.await.unwrap().is_err());
    shutdown.await.unwrap().unwrap();
    assert!(controller.state_node().is_none());
    // Abort explicitly closed the node; it must not revive a Running
    // snapshot whose watcher has already been invalidated.
    controller.publish_if_current(
        old_generation,
        Snapshot {
            state: "running",
            dns_name: Some("stale.example.ts.net".into()),
            ips: vec!["100.64.0.2".into()],
            ..Snapshot::default()
        },
    );
    assert_eq!(controller.snapshot().state, "stopped");
    assert!(controller.snapshot().dns_name.is_none());
    assert!(controller.snapshot().ips.is_empty());
    tokio::task::spawn_blocking(move || {
        assert_eq!(node.ips().unwrap_err().0, "node closed");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn logout_during_start_waits_for_the_original_close() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "test");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "test");
    let (creating, created) = tokio::sync::oneshot::channel();
    let (publish, unpublished) = std::sync::mpsc::channel();
    let starting_node = Arc::clone(&node);
    *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
        let _ = creating.send(());
        unpublished.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
        Ok(starting_node)
    }));
    let (closing, release) = block_close(&controller);
    let mut changes = controller.subscribe();
    let start = {
        let c = controller.clone();
        tokio::spawn(async move { c.start().await })
    };
    created.await.unwrap();
    assert_eq!(changes.recv().await.unwrap().state, "starting");
    let logout = {
        let c = controller.clone();
        tokio::spawn(async move { c.logout().await })
    };
    assert_eq!(changes.recv().await.unwrap().state, "stopped");
    publish.send(()).unwrap();
    closing.await.unwrap();
    // A second logout during the close must keep the state-owned handle.
    controller.request_logout();
    let retained = controller.state_node().expect("closing node remains controller-owned");
    assert!(Arc::ptr_eq(&retained, &node));
    release_node(retained);
    assert!(!controller.snapshot().running());
    assert!(controller.node().is_none());
    let replacement_created = Arc::new(AtomicBool::new(false));
    let created = replacement_created.clone();
    *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
        created.store(true, Ordering::Release);
        Err("replacement factory reached".into())
    }));
    let mut retry = {
        let c = controller.clone();
        tokio::spawn(async move { c.start().await })
    };
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(3100), &mut retry).await.is_err()
    );
    assert!(!replacement_created.load(Ordering::Acquire), "no replacement before close completes");
    release.send(()).unwrap();
    assert!(start.await.unwrap().is_err());
    assert_eq!(logout.await.unwrap().unwrap_err(), late_logout_error());
    assert!(retry.await.unwrap().is_err());
    assert!(replacement_created.load(Ordering::Acquire));
    tokio::task::spawn_blocking(move || {
        assert_eq!(node.ips().unwrap_err().0, "node closed");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn cancelled_resume_keeps_startup_serialized_with_logout() {
    startup_logout_interleaving(true, false).await;
}

#[tokio::test]
async fn shutdown_during_start_preserves_pending_logout_receipt() {
    startup_logout_interleaving(false, true).await;
}

async fn startup_logout_interleaving(cancel_resume: bool, shutdown: bool) {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "test");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "test");
    std::fs::write(temporary.path().join("enabled"), b"1\n").unwrap();
    let (creating, created) = tokio::sync::oneshot::channel();
    let (publish, unpublished) = std::sync::mpsc::channel();
    let starting_node = Arc::clone(&node);
    let saved_state = temporary.path().join("tailscaled.state");
    *controller.node_factory.lock().unwrap() = Some(Box::new(move || {
        let _ = creating.send(());
        unpublished.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
        // Model startup writing saved state after the caller was cancelled.
        std::fs::write(saved_state, b"saved login").unwrap();
        Ok(starting_node)
    }));
    let mut changes = controller.subscribe();
    let startup = {
        let c = controller.clone();
        tokio::spawn(async move {
            if cancel_resume { c.resume().await } else { c.start().await.map(|_| ()) }
        })
    };
    created.await.unwrap();
    assert_eq!(changes.recv().await.unwrap().state, "starting");
    if cancel_resume {
        startup.abort();
    }
    let mut logout = {
        let c = controller.clone();
        tokio::spawn(async move { c.logout().await })
    };
    assert_eq!(changes.recv().await.unwrap().state, "stopped");
    if shutdown {
        controller.begin_shutdown();
    }
    let waiting =
        tokio::time::timeout(std::time::Duration::from_millis(50), &mut logout).await.is_err();
    // Unblock the worker even when the assertion would fail on old code.
    publish.send(()).unwrap();
    assert!(waiting, "logout must wait for startup reconciliation");
    assert!(
        startup
            .await
            .unwrap_or_else(|error| {
                assert!(cancel_resume && error.is_cancelled());
                Err("resume caller cancelled".into())
            })
            .is_err()
    );
    assert_eq!(logout.await.unwrap().unwrap_err(), late_logout_error());
    assert!(!temporary.path().join("enabled").exists());
    assert!(!temporary.path().join("tailscaled.state").exists());
    assert!(controller.node().is_none());
    controller.shutdown().await.unwrap();
    tokio::task::spawn_blocking(move || {
        assert_eq!(node.ips().unwrap_err().0, "node closed");
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn retirement_preserves_remote_logout_completion_for_the_waiter() {
    for (late, remote_result, shutdown_first, shutdown_before_plan) in [
        (true, Ok(()), false, false),
        (true, Ok(()), true, false),
        (false, Ok(()), false, false),
        (false, Ok(()), true, false),
        (false, Err("remote logout failed".to_owned()), false, false),
        (false, Err("remote logout failed".to_owned()), true, false),
        (true, Ok(()), false, true),
        (true, Ok(()), true, true),
        (false, Ok(()), false, true),
    ] {
        let temporary = tempfile::tempdir().unwrap();
        let config = NodeConfig::new(temporary.path(), "test");
        let node = tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap()))
            .await
            .unwrap();
        std::fs::write(temporary.path().join("tailscaled.state"), b"identity").unwrap();
        let controller = Controller::new(temporary.path(), "test");
        controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
        let (owned, generation) =
            controller.begin_listener_retirement(Some(&node), "stopped").unwrap();
        release_node(owned.unwrap());
        if !late {
            controller.request_logout();
        }
        if shutdown_before_plan {
            controller.begin_shutdown();
        }
        let plan = controller.begin_retirement_close(generation, &node);
        assert_eq!(plan.logout, !late);
        if late {
            controller.request_logout();
        }
        let closing_node = Arc::clone(&node);
        tokio::task::spawn_blocking(move || closing_node.close().unwrap()).await.unwrap();
        assert!(controller.finish_retirement(generation, &node, plan, Ok(remote_result.clone())));
        let expected = if late { Err(late_logout_error()) } else { remote_result };
        if shutdown_first {
            controller.shutdown().await.unwrap();
        }
        assert_eq!(controller.logout().await.map(|_| ()), expected);
        assert!(!temporary.path().join("tailscaled.state").exists());
        assert!(controller.state_node().is_none());
        release_node(node);
    }
}

#[tokio::test]
async fn queued_logout_clears_opt_in_before_retirement_signs_out() {
    // A login holds the lifecycle gate, a listener fails (its cleanup
    // queues first), then logout queues behind that cleanup. The cleanup
    // performs the remote sign-out; the marker must already be gone, or a
    // daemon restart during that sign-out resumes the saved identity.
    let temporary = tempfile::tempdir().unwrap();
    std::fs::set_permissions(temporary.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    let marker = temporary.path().join("enabled");
    std::fs::write(&marker, b"1\n").unwrap();
    let config = NodeConfig::new(temporary.path(), "queued-logout");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "queued-logout");
    controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
    let (seen, marker_seen) = std::sync::mpsc::channel();
    let observed = marker.clone();
    *controller.remote_logout.lock().unwrap() = Some(Box::new(move || {
        let _ = seen.send(observed.exists());
        Ok(())
    }));
    let login = controller.lifecycle.lock().await;
    let failing = controller.clone();
    let failed = Arc::clone(&node);
    let failure = tokio::spawn(async move { failing.listener_failed(&failed).await });
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    let signing_out = controller.clone();
    let logout = tokio::spawn(async move { signing_out.logout().await });
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    drop(login);
    failure.await.unwrap();
    let result = logout.await.unwrap();
    assert!(
        !marker_seen.recv_timeout(std::time::Duration::from_secs(5)).unwrap(),
        "remote sign-out ran while the opt-in marker could still resume the node"
    );
    assert!(result.is_ok(), "{result:?}");
    assert!(!marker.exists());
    assert!(controller.state_node().is_none());
    release_node(node);
}

#[tokio::test]
async fn watch_start_failure_clears_opt_in_before_remote_sign_out() {
    let temporary = tempfile::tempdir().unwrap();
    std::fs::set_permissions(temporary.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    let marker = temporary.path().join("enabled");
    std::fs::write(&marker, b"1\n").unwrap();
    let config = NodeConfig::new(temporary.path(), "watch-logout");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "watch-logout");
    controller.inner.lock().unwrap().state = LifecycleState::Running(Arc::clone(&node));
    controller.request_logout();
    let (seen, marker_seen) = std::sync::mpsc::channel();
    let observed = marker.clone();
    *controller.remote_logout.lock().unwrap() = Some(Box::new(move || {
        let _ = seen.send(observed.exists());
        Ok(())
    }));
    controller.finish_watch_start_failure(Arc::clone(&node), "no watch thread").await;
    assert!(
        !marker_seen.recv_timeout(std::time::Duration::from_secs(5)).unwrap(),
        "remote sign-out ran while the opt-in marker could still resume the node"
    );
    assert!(!marker.exists());
    release_node(node);
}

#[tokio::test]
async fn watch_end_after_the_shutdown_fence_leaves_the_node_to_shutdown() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "fenced-watch");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "fenced-watch");
    controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
    controller.begin_shutdown();
    // The watcher's terminal callback during the fenced interval.
    tokio::time::timeout(std::time::Duration::from_secs(1), controller.listener_failed(&node))
        .await
        .expect("a fenced watch end queues no retirement");
    let retained = controller.node().expect("shutdown, not the watcher, closes the node");
    assert!(Arc::ptr_eq(&retained, &node));
    release_node(retained);
    assert!(!controller.retirement_pending());
    assert!(controller.snapshot().error.is_none());
    controller.shutdown().await.unwrap();
    assert!(controller.state_node().is_none());
    release_node(node);
}

#[tokio::test]
async fn watch_cleanup_queued_before_the_fence_leaves_the_close_to_shutdown() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "queued-cleanup");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "queued-cleanup");
    controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
    // A login holds the lifecycle gate; the watcher ends and its cleanup
    // queues behind it. Then the shutdown fence lands and login finishes
    // before the daemon's WebSocket shutdown.
    let login = controller.lifecycle.lock().await;
    let watcher = {
        let (controller, node) = (controller.clone(), Arc::clone(&node));
        tokio::spawn(async move { controller.listener_failed(&node).await })
    };
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    controller.begin_shutdown();
    drop(login);
    tokio::time::timeout(std::time::Duration::from_secs(5), watcher)
        .await
        .expect("queued cleanup finished")
        .unwrap();
    let retained =
        controller.state_node().expect("the queued cleanup must leave the close to shutdown");
    assert!(Arc::ptr_eq(&retained, &node));
    release_node(retained);
    assert!(!controller.retirement_pending());
    // A start or resume arriving now must not wait on the deferred
    // retirement, which no watcher will ever notify again.
    tokio::time::timeout(std::time::Duration::from_secs(1), controller.start())
        .await
        .expect("a start after the fence returns instead of waiting on retirement")
        .expect_err("nothing starts after the fence");
    tokio::time::timeout(std::time::Duration::from_secs(1), controller.resume())
        .await
        .expect("a resume after the fence returns instead of waiting on retirement")
        .unwrap();
    controller.shutdown().await.unwrap();
    assert!(controller.state_node().is_none());
    release_node(node);
}

#[tokio::test]
async fn a_failure_close_the_pool_runs_after_the_fence_never_closes() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "late-close");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "late-close");
    controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
    // The cleanup passed every async check and queued its close, but the
    // blocking pool runs it only after the fence and well past its bound.
    let (queued, queued_seen) = tokio::sync::oneshot::channel();
    let (run, delayed) = std::sync::mpsc::channel::<()>();
    *controller.before_admission.lock().unwrap() = Some(Box::new(move || {
        let _ = queued.send(());
        delayed.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
    }));
    *controller.before_close.lock().unwrap() =
        Some(Box::new(|| panic!("a close admitted after the fence")));
    let watcher = {
        let (controller, node) = (controller.clone(), Arc::clone(&node));
        tokio::spawn(async move { controller.listener_failed(&node).await })
    };
    queued_seen.await.unwrap();
    tokio::time::timeout(FENCE_CLOSE_BOUND + std::time::Duration::from_secs(1), controller.fence())
        .await
        .expect("the fence returns within its bound");
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    run.send(()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), watcher)
        .await
        .expect("the late cleanup finished")
        .unwrap();
    let retained = controller.state_node().expect("daemon shutdown, not the late job, closes");
    assert!(Arc::ptr_eq(&retained, &node));
    release_node(retained);
    assert!(!controller.retirement_pending());
    controller.shutdown().await.unwrap();
    assert!(controller.state_node().is_none());
    release_node(node);
}

#[tokio::test]
async fn the_fence_waits_for_a_failure_close_already_under_way() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "close-under-way");
    let node =
        tokio::task::spawn_blocking(move || Arc::new(Node::new(&config).unwrap())).await.unwrap();
    let controller = Controller::new(temporary.path(), "close-under-way");
    controller.set_running_for_test(Arc::clone(&node), "node.example.ts.net");
    let (closing, release) = block_close(&controller);
    let watcher = {
        let (controller, node) = (controller.clone(), Arc::clone(&node));
        tokio::spawn(async move { controller.listener_failed(&node).await })
    };
    // The cleanup passed its shutdown check and is inside its close.
    closing.await.unwrap();
    let mut fence = {
        let controller = controller.clone();
        tokio::spawn(async move { controller.fence().await })
    };
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(50), &mut fence).await.is_err(),
        "the fence must not return while an admitted close is under way"
    );
    release.send(()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(2), fence)
        .await
        .expect("the fence returns once the admitted close finished")
        .unwrap();
    watcher.await.unwrap();
    assert!(controller.state_node().is_none());
    controller.shutdown().await.unwrap();
    release_node(node);
}

#[test]
fn saved_opt_in_refuses_a_marker_that_is_not_a_private_regular_file() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let temporary = tempfile::tempdir().unwrap();
    let state = temporary.path().join("tailnet");
    std::fs::create_dir(&state).unwrap();
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
    let marker = state.join("enabled");
    let elsewhere = temporary.path().join("elsewhere");
    std::fs::write(&elsewhere, b"1\n").unwrap();
    symlink(&elsewhere, &marker).unwrap();
    assert!(saved_opt_in(&marker).is_err(), "a symlinked marker is not followed");
    std::fs::remove_file(&marker).unwrap();

    std::fs::write(&marker, b"1\n").unwrap();
    assert!(saved_opt_in(&marker).unwrap());
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o770)).unwrap();
    assert!(saved_opt_in(&marker).is_err(), "a shared state directory is refused");
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::remove_file(&marker).unwrap();

    let fifo = CString::new(marker.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: mkfifo with a NUL-terminated path inside our temporary directory.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    let (done, finished) = std::sync::mpsc::channel();
    let reading = marker.clone();
    std::thread::spawn(move || {
        let _ = done.send(saved_opt_in(&reading));
    });
    let result = finished
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("reading a FIFO marker must not block daemon startup");
    assert!(result.is_err(), "a FIFO is not a marker");
}

#[test]
fn resume_error_cannot_replace_a_newer_start_or_shutdown() {
    for action in ["start", "logout", "shutdown"] {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", action);
        let generation = controller.inner.lock().unwrap().generation;
        match action {
            "start" => {
                let mut inner = controller.inner.lock().unwrap();
                inner.generation += 1;
                inner.snapshot = Snapshot {
                    state: "running",
                    dns_name: Some("new.example.ts.net".into()),
                    ips: vec!["100.64.0.2".into()],
                    ..Snapshot::default()
                };
            }
            "logout" => controller.request_logout(),
            _ => controller.begin_shutdown(),
        }
        let newer = controller.snapshot();
        let mut changes = controller.subscribe();
        controller.note_resume_error_if_current(generation, "old resume failed");
        assert_eq!(controller.snapshot(), newer, "{action}");
        assert!(changes.try_recv().is_err(), "{action}");
    }
}

#[tokio::test]
async fn current_resume_marker_error_is_published_before_return() {
    let temporary = tempfile::tempdir().unwrap();
    std::fs::create_dir(temporary.path().join("enabled")).unwrap();
    let controller = Controller::new(temporary.path(), "test");
    let error = controller.resume().await.unwrap_err();
    assert_eq!(controller.snapshot().state, "error");
    assert_eq!(controller.snapshot().error.as_deref(), Some(error.as_str()));
}

#[test]
fn sign_in_url_is_redacted_for_non_person_consumers() {
    let snapshot = Snapshot {
        state: "needs_login",
        browse_to_url: Some("https://login.tailscale.com/fake".into()),
        ..Snapshot::default()
    };
    assert!(snapshot.to_json(false).get("browse_to_url").is_none());
    assert_eq!(snapshot.to_json(true)["browse_to_url"], "https://login.tailscale.com/fake");
}

#[test]
fn state_change_clears_stale_login_url_and_network_identity() {
    let mut snapshot = Snapshot {
        state: "needs_login",
        browse_to_url: Some("https://login.tailscale.com/fake".into()),
        dns_name: Some("cmux.example.ts.net".into()),
        ips: vec!["100.64.0.1".into()],
        ..Snapshot::default()
    };
    let notify = Notify { state: Some(5), ..Notify::default() };
    snapshot.apply_notify(&notify, None);
    assert_eq!(snapshot.state, "starting");
    assert!(snapshot.browse_to_url.is_none());
    assert!(snapshot.dns_name.is_none());
    assert!(snapshot.ips.is_empty());
}

#[test]
fn a_running_name_notification_refresh_clears_a_stale_identity() {
    // NetMap rename notifications have no BackendState. The watcher
    // supplies the live status separately, so the actual notification
    // path must replace the old certificate/SNI identity.
    let mut snapshot = Snapshot {
        state: "running",
        dns_name: Some("old.example.ts.net".into()),
        ips: vec!["100.64.0.1".into()],
        ..Snapshot::default()
    };
    snapshot.apply_notify_with_status(
        &Notify::default(),
        Some(LiveIdentity {
            state: BackendState::Running,
            dns_name: Some("new.example.ts.net".into()),
            ips: vec!["100.64.0.2".into()],
        }),
    );
    assert_eq!(snapshot.dns_name.as_deref(), Some("new.example.ts.net"));
    assert_eq!(snapshot.ips, ["100.64.0.2"]);

    snapshot.apply_notify_with_status(
        &Notify::default(),
        Some(LiveIdentity { state: BackendState::Running, dns_name: None, ips: vec![] }),
    );
    assert_eq!(snapshot.state, "running");
    assert!(snapshot.dns_name.is_none());
    assert!(snapshot.ips.is_empty());
}

#[test]
fn an_ended_node_leaves_no_sign_in_url_or_identity() {
    let mut snapshot = Snapshot {
        state: "running",
        browse_to_url: Some("https://login.tailscale.com/fake".into()),
        dns_name: Some("cmux.example.ts.net".into()),
        ips: vec!["100.64.0.1".into()],
        error: Some("watch ended".into()),
    };
    snapshot.node_gone("stopped");
    assert_eq!(snapshot.state, "stopped");
    assert!(snapshot.browse_to_url.is_none());
    assert!(snapshot.dns_name.is_none());
    assert!(snapshot.ips.is_empty());
    assert_eq!(snapshot.error.as_deref(), Some("watch ended"));
}

#[tokio::test]
async fn a_dropped_caller_does_not_cancel_lifecycle_work() {
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let (release_tx, release_rx) = tokio::sync::oneshot::channel::<()>();
    let (done_tx, done_rx) = tokio::sync::oneshot::channel();
    let caller = tokio::spawn(detached(async move {
        let _ = started_tx.send(());
        let _ = release_rx.await;
        let _ = done_tx.send(());
        Ok::<_, String>(())
    }));
    started_rx.await.unwrap();
    caller.abort();
    let _ = caller.await;
    release_tx.send(()).unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), done_rx)
        .await
        .expect("detached lifecycle work finished after its caller was dropped")
        .unwrap();
}

#[tokio::test]
async fn listener_failure_retires_state_before_a_slow_close() {
    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
    controller.update(|snapshot| snapshot.state = "running");
    let lifecycle = controller.lifecycle.lock().await;

    // A login/logout request can hold the lifecycle lock longer than the
    // supervisor's three-second close bound. Retirement must happen before
    // cleanup waits for that lock, so the service cannot restart this node.
    let Some((None, retired_generation)) = controller.begin_listener_retirement(None, "stopped")
    else {
        panic!("retiring an empty controller still records its generation");
    };
    let (closed, closed_rx) = tokio::sync::oneshot::channel();
    let cleanup = spawn_after_retirement(
        Arc::clone(&controller.retirement_gate),
        Arc::clone(&controller.lifecycle),
        {
            let controller = controller.clone();
            move || async move {
                controller.note_listener_error_if_current(retired_generation);
                controller.pending_retirement.store(false, Ordering::Release);
                controller.retirement_finished.notify_waiters();
                let _ = closed.send(());
            }
        },
    );
    let (started, started_rx) = tokio::sync::oneshot::channel();
    let queued = controller.clone();
    let mut start = tokio::spawn(async move {
        let _gate = queued.await_retirement_gate().await;
        let _lifecycle = queued.lifecycle.lock().await;
        let _ = started.send(queued.snapshot().state);
    });
    assert!(tokio::time::timeout(std::time::Duration::from_millis(10), cleanup).await.is_err());
    assert!(tokio::time::timeout(std::time::Duration::from_millis(10), &mut start).await.is_err());
    assert_eq!(controller.snapshot().state, "stopped");
    assert!(controller.node().is_none());
    drop(lifecycle);
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        closed_rx.await.expect("detached close sent completion");
    })
    .await
    .expect("detached close completed after lifecycle lock was released");
    assert_eq!(started_rx.await.expect("queued start ran after retirement"), "error");
    start.await.expect("queued start task completed");
}

#[tokio::test]
async fn queued_start_waits_for_retirement_cleanup() {
    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
    let retirement = controller.retirement_gate.lock().await;
    let lifecycle = controller.lifecycle.lock().await;
    let (cleanup_done, cleanup_rx) = tokio::sync::oneshot::channel();
    let cleanup = spawn_after_retirement(
        Arc::clone(&controller.retirement_gate),
        Arc::clone(&controller.lifecycle),
        move || async move {
            let _ = cleanup_done.send(());
        },
    );
    let (start_done, start_rx) = tokio::sync::oneshot::channel();
    let start = spawn_after_retirement(
        Arc::clone(&controller.retirement_gate),
        Arc::clone(&controller.lifecycle),
        move || async move {
            let _ = start_done.send(());
        },
    );
    drop(retirement);
    assert!(tokio::time::timeout(std::time::Duration::from_millis(10), cleanup).await.is_err());
    assert!(tokio::time::timeout(std::time::Duration::from_millis(10), start).await.is_err());
    drop(lifecycle);
    tokio::time::timeout(std::time::Duration::from_secs(1), cleanup_rx)
        .await
        .expect("retirement cleanup completed")
        .expect("retirement cleanup sent completion");
    tokio::time::timeout(std::time::Duration::from_secs(1), start_rx)
        .await
        .expect("queued start ran after retirement cleanup")
        .expect("queued start sent completion");
}

#[test]
fn lifecycle_table_keeps_logout_inside_retirement() {
    // Exercise the short-mutex transitions as a table so the two
    // interleavings that used to lose saved credentials stay explicit:
    // retirement first, and logout first while retirement is pending.
    let cases = [
        (
            "retire",
            LifecycleState::Retiring { node: None, phase: RetirementPhase::Waiting },
            "stopped",
        ),
        (
            "logout-during-retire",
            LifecycleState::LoggingOut { node: None, remote_result: None },
            "stopped",
        ),
        ("logout-during-start", LifecycleState::Starting, "starting"),
    ];
    for (name, state, snapshot_state) in cases {
        let controller = Controller::new("/nonexistent/cmux-tailnet-test", name);
        {
            let mut inner = controller.inner.lock().unwrap();
            inner.state = state;
            inner.snapshot.node_gone(snapshot_state);
        }
        assert!(controller.node().is_none(), "{name} exposes no replacement node");
        assert_eq!(controller.snapshot().state, snapshot_state, "{name}");
    }

    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "logout");
    controller.begin_listener_retirement(None, "stopped");
    controller.request_logout();
    assert!(matches!(
        &controller.inner.lock().unwrap().state,
        LifecycleState::LoggingOut { node: None, remote_result: None }
    ));

    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "starting");
    let generation = controller.inner.lock().unwrap().generation;
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.state = LifecycleState::Starting;
    }
    controller.request_logout();
    assert!(matches!(
        &controller.inner.lock().unwrap().state,
        LifecycleState::LoggingOut { node: None, remote_result: None }
    ));
    assert!(controller.inner.lock().unwrap().generation > generation);
}

#[test]
fn watch_start_failure_preserves_the_remote_logout_result() {
    let temporary = tempfile::tempdir().unwrap();
    let config = NodeConfig::new(temporary.path(), "watch-failure");
    let node = Arc::new(Node::new(&config).unwrap());
    let controller = Controller::new(temporary.path(), "watch-failure");
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.state = LifecycleState::Retiring {
            node: Some(Arc::clone(&node)),
            phase: RetirementPhase::ClosingForLogout,
        };
    }
    controller.finish_start_close(0, &node, true, true, Ok(Err("remote logout failed".to_owned())));
    let inner = controller.inner.lock().unwrap();
    match &inner.state {
        LifecycleState::LoggingOut { node: None, remote_result: Some(Err(error)) } => {
            assert_eq!(error, "remote logout failed");
        }
        _ => panic!("pending logout result was discarded or changed"),
    }
    drop(inner);
    release_node(node);
}

#[tokio::test]
async fn failed_marker_removal_rolls_back_logout_and_wakes_start() {
    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "remove-failure");
    controller.request_logout();
    controller.abort_logout("remove enabled failed").await;
    assert!(matches!(&controller.inner.lock().unwrap().state, LifecycleState::Stopped));
    tokio::time::timeout(std::time::Duration::from_secs(1), controller.start())
        .await
        .expect("start is not left waiting on the failed logout transition")
        .expect_err("the test state directory is intentionally unavailable");
}

#[test]
fn release_on_background_drops_after_the_caller_thread() {
    let caller = std::thread::current().id();
    let (dropped, received) = std::sync::mpsc::channel();
    struct Probe(std::sync::mpsc::Sender<std::thread::ThreadId>);
    impl Drop for Probe {
        fn drop(&mut self) {
            let _ = self.0.send(std::thread::current().id());
        }
    }
    release_on_background(Probe(dropped));
    let dropper = received.recv_timeout(std::time::Duration::from_secs(1)).unwrap();
    assert_ne!(dropper, caller);
}

#[tokio::test]
async fn no_node_starts_after_shutdown() {
    let controller = Controller::new("/nonexistent/cmux-tailnet-test", "test");
    controller.shutdown().await.unwrap();
    assert_eq!(controller.start().await, Err("the daemon is shutting down".to_owned()));
    assert!(controller.node().is_none());
    assert_eq!(controller.snapshot().state, "stopped");
}

#[test]
fn stale_watch_generation_cannot_publish_after_logout() {
    let controller = Controller::new("/tmp/cmux-tailnet-test", "test");
    {
        let mut inner = controller.inner.lock().unwrap();
        inner.generation = 2;
    }
    controller.update_if_current(1, |snapshot| snapshot.state = "running");
    assert_eq!(controller.snapshot().state, "not_started");
}
