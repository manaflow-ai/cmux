//! A saved Auto chat is frozen from the moment its session exists, before the holder loop has
//! heard the store: no restored prompt or adoption runs it until the store says it is this
//! machine's still (`auto_hold.rs`).

use std::time::Duration;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{Holder, PutRequest};

use super::*;
use crate::auto_session::runtime::ManualClock;
use crate::auto_session::{
    HolderOptions, ImportError, ImportReason, Imported, SessionImporter, spawn_holder_with,
};

const OTHER_HOLDS: &str = "other-holds";
const CLOUD_DOWN: &str = "cloud-down";
const MINE: &str = "mine";

struct NoImport;

impl SessionImporter for NoImport {
    fn import<'a>(
        &'a self,
        _: &'a cmux_auto_session::wire::SessionView,
        _: ImportReason,
    ) -> futures::future::BoxFuture<'a, Result<Imported, ImportError>> {
        Box::pin(async { Err(ImportError::Local("no import in this test".into())) })
    }
}

/// A chat this laptop held when its daemon stopped, as the store loads it.
fn saved(hub: &Arc<Hub>, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "autoSession": {"auto": true, "here": true, "epoch": 1, "snapshot": 1, "state": "local"},
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

async fn register(cloud: &FakeAutoCloud, id: &str, device: &str) {
    let put = PutRequest {
        auto: true,
        title: String::new(),
        harness: "fake".into(),
        device: device.into(),
        keep_in_cloud: None,
        repo: None,
    };
    cloud.put(id, &put).await.expect("the store takes the chat");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn saved_auto_chats_do_no_local_work_until_the_store_confirms() {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let (cloud, clock) = (FakeAutoCloud::new(), ManualClock::new(1_700_000_000_000));
    cloud.set_now(1_700_000_000_000);
    register(&cloud.as_owner(), OTHER_HOLDS, "laptop-2").await;
    register(&cloud.as_owner(), MINE, "laptop-1").await;

    // The daemon will run the loop: its saved Auto chats are frozen as they load.
    hub.expect_auto();
    let others = saved(&hub, OTHER_HOLDS);
    let down = saved(&hub, CLOUD_DOWN);
    let mine = saved(&hub, MINE);
    for chat in [&others, &down, &mine] {
        assert!(hub.auto_held(chat), "{} was free before the store spoke", chat.id);
    }

    // The loop starts; the store is reachable for two chats of three and says one is another
    // device's. The restored queues are resumed, as the daemon does after adoption.
    let reach = cloud.as_owner();
    let options = HolderOptions { clock: clock.clone(), network: None, new_chats: None };
    spawn_holder_with(
        hub.clone(),
        Arc::new(reach),
        Holder::device("laptop-1"),
        Arc::new(NoImport),
        options,
    );
    hub.resume_queues();
    tokio::time::sleep(Duration::from_millis(600)).await;

    assert!(hub.auto_held(&others), "the chat another device holds ran here");
    assert!(hub.auto_held(&down), "a chat the store does not know ran here");
    assert!(!hub.auto_held(&mine), "the chat the store says is this laptop's stayed frozen");
}
