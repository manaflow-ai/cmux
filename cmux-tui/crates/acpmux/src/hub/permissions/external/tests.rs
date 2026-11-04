use super::*;
use std::{future::Future, pin::Pin, task::Poll};

fn fixture(policy: PermissionPolicy) -> (Arc<Hub>, Arc<Session>) {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    config.permission_policy = policy;
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "external-read", "name": "Read",
        "harness": "claude", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    (hub, session)
}

async fn pending<T>(mut future: Pin<&mut impl Future<Output = T>>) {
    std::future::poll_fn(|cx| {
        assert!(future.as_mut().poll(cx).is_pending(), "external read must wait for the person");
        Poll::Ready(())
    })
    .await;
}

async fn answer(hub: &Hub, session: &Session, option: &str, person: bool) -> Result<(), RpcError> {
    let id = session.permissions.lock().unwrap().pending.keys().next().unwrap().clone();
    hub.respond_permission(
        session,
        &id,
        Some(option.into()),
        None,
        None,
        super::super::super::person::Answerer { person, ..Default::default() },
        Control::Local,
    )
    .await
}

#[test]
fn external_access_classification_is_not_a_generic_permission_error() {
    let home = Some(Path::new("/Users/you"));
    let denied = std::io::Error::from_raw_os_error(libc::EPERM);
    assert_eq!(
        classify(&denied, Path::new("/Users/you/Documents/a.txt"), home, true),
        Some(AccessKind::FilesAndFolders)
    );
    assert_eq!(
        classify(&denied, Path::new("/Users/you/Library/Mail/a"), home, true),
        Some(AccessKind::FullDiskAccess)
    );
    for path in ["/", "/Users/you", "/Users/you/src/a", "/Users/you/Documents-old/a"] {
        assert_eq!(classify(&denied, Path::new(path), home, true), None);
    }
    assert_eq!(classify(&denied, Path::new("/Users/you/Documents/a"), home, false), None);
    assert_eq!(
        classify(
            &std::io::Error::from_raw_os_error(libc::EACCES),
            Path::new("/Users/you/Documents/a"),
            home,
            true
        ),
        None
    );
}

#[tokio::test]
async fn external_access_bypass_and_chat_allowance_still_wait_then_retry_once() {
    let (hub, session) = fixture(PermissionPolicy::ApproveAll);
    session.permissions.lock().unwrap().chat_allowed = true;
    let calls = std::cell::Cell::new(0);
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let mut read = Box::pin(hub.retry_external_read(
        &session,
        Path::new("/Users/you/Documents/a"),
        epoch,
        None,
        AccessKind::FilesAndFolders,
        || {
            calls.set(calls.get() + 1);
            Ok("visible content".into())
        },
    ));
    pending(read.as_mut()).await;
    assert_eq!(calls.get(), 0);
    hub.approve_pending_tools(&session).await;
    pending(read.as_mut()).await;
    assert!(
        answer(&hub, &session, "allow_once", false).await.is_err(),
        "an agent cannot grant itself access"
    );
    answer(&hub, &session, "allow_once", true).await.unwrap();
    assert_eq!(read.await.unwrap(), "visible content");
    assert_eq!(calls.get(), 1);
    assert!(session.permissions.lock().unwrap().pending.is_empty());
}

#[tokio::test]
async fn external_access_skip_cancel_and_drop_never_retry() {
    for action in ["skip", "cancel", "drop"] {
        let (hub, session) = fixture(PermissionPolicy::ApproveAll);
        let calls = std::cell::Cell::new(0);
        let epoch = session.permission_epoch.load(Ordering::SeqCst);
        let mut read = Box::pin(hub.retry_external_read(
            &session,
            Path::new("/Users/you/Documents/a"),
            epoch,
            None,
            AccessKind::FilesAndFolders,
            || {
                calls.set(calls.get() + 1);
                Ok("unexpected".into())
            },
        ));
        pending(read.as_mut()).await;
        match action {
            "skip" => {
                answer(&hub, &session, "reject_once", true).await.unwrap();
                assert!(read.await.is_err());
            }
            "cancel" => {
                hub.cancel_pending_permissions(&session);
                assert!(read.await.is_err());
            }
            _ => drop(read),
        }
        assert_eq!(calls.get(), 0, "{action}");
        assert!(session.permissions.lock().unwrap().pending.is_empty(), "{action}");
    }
}

#[tokio::test]
async fn external_access_persistent_os_denial_returns_error_without_asking_again() {
    let (hub, session) = fixture(PermissionPolicy::ApproveAll);
    let calls = std::cell::Cell::new(0);
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let mut read = Box::pin(hub.retry_external_read(
        &session,
        Path::new("/Users/you/Documents/a"),
        epoch,
        None,
        AccessKind::FilesAndFolders,
        || {
            calls.set(calls.get() + 1);
            Err(std::io::Error::from_raw_os_error(libc::EPERM))
        },
    ));
    pending(read.as_mut()).await;
    answer(&hub, &session, "allow_once", true).await.unwrap();
    assert!(read.await.is_err());
    assert_eq!(calls.get(), 1);
    assert!(session.permissions.lock().unwrap().pending.is_empty());
}

#[tokio::test]
async fn external_access_stop_after_allow_still_prevents_the_read() {
    let (hub, session) = fixture(PermissionPolicy::ApproveAll);
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let mut read = Box::pin(hub.retry_external_read(
        &session,
        Path::new("/Users/you/Documents/a"),
        epoch,
        None,
        AccessKind::FilesAndFolders,
        || panic!("a cancelled turn cannot retry"),
    ));
    pending(read.as_mut()).await;
    answer(&hub, &session, "allow_once", true).await.unwrap();
    hub.cancel_pending_permissions(&session);
    assert!(read.await.is_err());
}
